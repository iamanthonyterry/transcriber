import AppKit
import SwiftUI

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
            MenuLabel(dot: model.statusDot)
        }
        .menuBarExtraStyle(.menu)

        Window("Live transcript", id: "transcript") {
            TranscriptView(model: model)
        }
        .defaultSize(width: 380, height: 260)

        Window("Website settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuLabel: View {
    let dot: String?
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "mic.fill")
            if let dot { Text(dot) }
        }
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
        Toggle("Only Sundays 8:00–12:30", isOn: Binding(get: { model.settings.scheduleOn }, set: { model.settings.scheduleOn = $0; model.apply() }))
        Divider()
        Button("Show transcript") {
            openWindow(id: "transcript")
            NSApp.activate(ignoringOtherApps: true)
        }
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
                Menu("Translate (\(model.settings.translateTo.count))") {
                    if model.languages.isEmpty { Text("Needs macOS 26 or newer") }
                    ForEach(model.languages) { lang in
                        Toggle(lang.name, isOn: Binding(get: { model.settings.translateTo.contains(lang.code) }, set: { _ in model.toggleLanguage(lang.code) }))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                Toggle("Keep on top", isOn: $floating).toggleStyle(.checkbox).font(.caption)
                Button("Clear") { model.lines.removeAll() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if !model.settings.translateTo.isEmpty {
                Toggle("Send translations to the website (viewers pick their language)", isOn: Binding(get: { model.settings.sendTranslations }, set: {
                    model.settings.sendTranslations = $0
                    model.saveSettings()
                })).toggleStyle(.checkbox).font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 4)
            }
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
                                Text(line.date, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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

private struct WindowLevelSetter: NSViewRepresentable {
    let floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = floating ? .floating : .normal }
    }
}
