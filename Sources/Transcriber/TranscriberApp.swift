import AppKit
import SwiftUI
import Translation

@main
struct TranscriberApp: App {
    @StateObject private var model = AppModel()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--transcribe-file"), i + 1 < CommandLine.arguments.count {
            FileTest.run(path: CommandLine.arguments[i + 1])  // dev/testing: print phrases from an audio file, then exit
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuLabel(tint: model.statusTint)
        }
        .menuBarExtraStyle(.menu)

        Window("Live transcript", id: "transcript") {
            TranscriptView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 380, height: 260)

        Window("Website settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuLabel: View {
    let tint: NSColor?

    var body: some View {
        // Menu bar icons are templates (always monochrome), so a colored mic has to be a pre-tinted, non-template image.
        if let tint, let img = Self.mic(tint) {
            Image(nsImage: img)
        } else {
            Image(systemName: "mic.fill")
        }
    }

    private static func mic(_ color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return nil }
        let img = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        img.isTemplate = false
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        Text(model.lastText.isEmpty ? "(nothing heard yet)" : "“\(model.lastText.prefix(70))\(model.lastText.count > 70 ? "…" : "")”")
        Divider()
        Button(model.running ? "Stop transcribing" : "Start transcribing") { model.toggle() }
        Divider()
        Picker("Audio input", selection: Binding(get: { model.settings.device ?? "" }, set: { model.settings.device = $0.isEmpty ? nil : $0; model.settings.channel = 1; model.apply() })) {
            Text("System default").tag("")
            ForEach(model.devices) { Text("\($0.name) (\($0.channels) ch)").tag($0.name) }
        }
        Picker("Input channel", selection: Binding(get: { model.settings.channel }, set: { model.settings.channel = $0; model.apply() })) {
            ForEach(1...model.channelCount, id: \.self) { Text("Channel \($0)").tag($0) }
        }
        Toggle("Only \(Schedule.summary(model.settings))", isOn: Binding(get: { model.settings.scheduleOn }, set: { model.settings.scheduleOn = $0; model.apply() }))
        Divider()
        Button("Show transcript") {
            openWindow(id: "transcript")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Save transcript now") {
            if !model.settings.saveFolder.isEmpty, model.saveTranscript(to: URL(fileURLWithPath: model.settings.saveFolder)) != nil { return }
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Save Here"
            NSApp.activate(ignoringOtherApps: true)
            if p.runModal() == .OK, let u = p.url { model.saveTranscript(to: u) }
        }
        .disabled(model.sessionLog.isEmpty)
        Button("Open live page") { if let u = model.liveURL() { NSWorkspace.shared.open(u) } }
        Button("Website settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
        if let install = model.pendingUpdate {
            Button("Restart to Update") { model.stop(); install() }
        } else {
            Button("Check for Updates…") { model.updates.checkForUpdates() }
        }
        Divider()
        Button("Quit") { model.stop(); NSApp.terminate(nil) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            TextField("Transcript address", text: $model.settings.url)
            SecureField("Campus key", text: $model.token)
            Text("The key comes from this campus’s page in the website’s admin area. It decides which campus this Mac feeds.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Behavior") {
                Toggle("Start listening when the app opens", isOn: $model.settings.autoStart)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }
            Section("Schedule") {
                Toggle("Only listen during this schedule", isOn: $model.settings.scheduleOn)
                Picker("Times from", selection: $model.settings.pcoOn) {
                    Text("Set manually").tag(false)
                    Text("Planning Center").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.settings.pcoOn) { _, on in if on { Task { await model.refreshPCOTimes() } } }
                if model.settings.pcoOn {
                    PlanningCenterSection(model: model)
                } else {
                    ForEach($model.settings.scheduleWindows) { $w in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker("", selection: Binding(get: { w.date != nil }, set: { w.date = $0 ? (w.date ?? Date()) : nil })) {
                                    Text("Repeats weekly").tag(false)
                                    Text("One time").tag(true)
                                }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                                Spacer()
                                Button(role: .destructive) {
                                    model.settings.scheduleWindows.removeAll { $0.id == w.id }
                                } label: { Image(systemName: "trash") }
                            }
                            if w.date != nil {
                                DatePicker("On", selection: Binding(get: { w.date ?? Date() }, set: { w.date = $0 }), displayedComponents: .date)
                                if let d = w.date, d < Calendar.current.startOfDay(for: Date()) {
                                    Text("This date has passed.").font(.caption).foregroundStyle(.orange)
                                }
                            } else {
                                HStack {
                                    ForEach(1...7, id: \.self) { d in
                                        Toggle(Calendar.current.veryShortWeekdaySymbols[d - 1], isOn: Binding(
                                            get: { w.days.contains(d) },
                                            set: { if $0 { w.days.insert(d) } else { w.days.remove(d) } }))
                                            .toggleStyle(.button)
                                    }
                                }
                            }
                            HStack {
                                DatePicker("From", selection: Binding(get: { Schedule.date(w.start) }, set: { w.start = Schedule.minutes($0) }), displayedComponents: .hourAndMinute)
                                DatePicker("to", selection: Binding(get: { Schedule.date(w.end) }, set: { w.end = Schedule.minutes($0) }), displayedComponents: .hourAndMinute)
                            }
                            if w.end <= w.start {
                                Text("End must be after start (same day).").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Add another time") { model.settings.scheduleWindows.append(ScheduleWindow()) }
                }
            }
            Section("Translation") {
                if model.languages.isEmpty {
                    Text("Translation needs macOS 26 or newer.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.languages) { lang in
                        Toggle(lang.name, isOn: Binding(get: { model.settings.translateTo.contains(lang.code) }, set: { _ in model.toggleLanguage(lang.code) }))
                    }
                    Toggle("Send translations to the website (viewers pick their language)", isOn: Binding(get: { model.settings.sendTranslations }, set: {
                        model.settings.sendTranslations = $0
                        model.saveSettings()
                    }))
                    .disabled(model.settings.translateTo.isEmpty)
                }
                if let note = model.translationNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Transcript copy") {
                Toggle("Save a copy of the transcript when a session ends", isOn: $model.settings.saveCopy)
                HStack {
                    Text(model.settings.saveFolder.isEmpty ? "No folder chosen" : model.settings.saveFolder)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        if p.runModal() == .OK, let u = p.url { model.settings.saveFolder = u.path }
                    }
                }
                Text("A session ends when you stop transcribing, quit, or the schedule’s end time passes. The whole session is kept (Clear only empties the window).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tuning") {
                TextField("Corrections", text: $model.settings.corrections, axis: .vertical)
                    .lineLimit(3...6)
                Text("One per line, written heard => correct (e.g. Life Point => Lifepoint). Fixes names and places Whisper keeps getting wrong.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Slider(value: $model.settings.minDb, in: -65...(-30), step: 1)
                    Text("\(Int(model.settings.minDb)) dB").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Text("Hears noise as speech? Raise this (try −42). Misses quiet speech? Lower it.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Save") {
                    model.apply()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .modifier(LanguageDownloader(model: model))
    }
}

struct PlanningCenterSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.pcoSignedIn {
            HStack {
                Button(model.pcoBusy ? "Waiting for the browser…" : "Sign in to Planning Center") { model.pcoSignIn() }
                    .disabled(model.pcoBusy || !PCOConfig.isConfigured)
                if model.pcoBusy { ProgressView().controlSize(.small) }
            }
            Text(PCOConfig.isConfigured ? "Opens Planning Center in your browser. Only service types and times are read."
                 : "This build has no Planning Center credentials (see Support/pco.env.example).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Service type", selection: Binding(get: { model.settings.pcoServiceTypeID ?? "" }, set: { model.selectPCOType($0.isEmpty ? nil : $0) })) {
                Text("Choose…").tag("")
                ForEach(model.pcoTypes) { Text($0.name).tag($0.id) }
                // keeps the saved choice visible before the list loads (or if it is offline)
                if let id = model.settings.pcoServiceTypeID, !model.pcoTypes.contains(where: { $0.id == id }) {
                    Text(model.settings.pcoServiceTypeName).tag(id)
                }
            }
            Stepper("Start \(model.settings.pcoLeadMinutes) min before the service", value: $model.settings.pcoLeadMinutes, in: 0...120, step: 5)
            Stepper("Stop \(model.settings.pcoLengthMinutes) min after it starts", value: $model.settings.pcoLengthMinutes, in: 15...300, step: 5)
            if model.settings.pcoServiceTypeID != nil {
                let upcoming = model.settings.pcoTimes.filter { Schedule.pcoWindow(model.settings, $0).upperBound > Date() }.prefix(4)
                if upcoming.isEmpty {
                    Text(model.pcoBusy ? "Loading service times…" : "No upcoming service times for this service type.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(upcoming), id: \.self) { t in
                    let w = Schedule.pcoWindow(model.settings, t)
                    Text("\(t.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): listens \(w.lowerBound.formatted(date: .omitted, time: .shortened))–\(w.upperBound.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                }
            }
            HStack {
                Button("Refresh times") { Task { await model.refreshPCOTimes() } }
                    .disabled(model.pcoBusy || model.settings.pcoServiceTypeID == nil)
                Spacer()
                Button("Sign out of Planning Center") { model.pcoSignOut() }
            }
        }
        if let e = model.pcoError { Text(e).font(.caption).foregroundStyle(.orange) }
    }
}

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var floating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.listening ? .red : (model.running ? .yellow : .gray)).frame(width: 8, height: 8)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Toggle("Keep on top", isOn: $floating).toggleStyle(.checkbox).font(.caption)
                Button("Clear") { model.lines.removeAll() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            if let note = model.translationNote {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.lines.isEmpty {
                            Text("Nothing heard yet").foregroundStyle(.secondary)
                        }
                        ForEach(model.lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.text).textSelection(.enabled)
                                    ForEach(model.settings.translateTo, id: \.self) { code in
                                        if let t = line.translations[code] {
                                            Text(t).foregroundStyle(.blue).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: model.lines.count) {
                    if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 160)
        .background(WindowLevelSetter(floating: floating))
    }
}

/// Shows Apple's "Download language?" prompt for languages picked in Settings (macOS 15+).
private struct LanguageDownloader: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.modifier(Prompt(model: model)) } else { content }
    }

    @available(macOS 15, *)
    private struct Prompt: ViewModifier {
        @ObservedObject var model: AppModel
        @State private var config: TranslationSession.Configuration?

        func body(content: Content) -> some View {
            content
                .translationTask(config) { session in
                    try? await session.prepareTranslation()
                    await MainActor.run { model.finishDownload() }
                }
                .onChange(of: model.downloadQueue.first, initial: true) { _, code in
                    config = code.map { .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: $0)) }
                }
        }
    }
}

private struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = view.window else { return }
            w.level = floating ? .floating : .normal
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        }
    }
}
