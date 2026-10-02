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

        Window("Website settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

private let menuIcon: NSImage? = {
    guard let url = Bundle.main.url(forResource: "menubarTemplate", withExtension: "png"), let img = NSImage(contentsOf: url) else { return nil }
    img.isTemplate = true
    img.size = NSSize(width: 18, height: 18)
    return img
}()

struct MenuLabel: View {
    let dot: String?
    var body: some View {
        HStack(spacing: 2) {
            if let menuIcon { Image(nsImage: menuIcon) } else if dot == nil { Text("🎙") }
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
