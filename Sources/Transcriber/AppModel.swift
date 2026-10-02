import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings
    @Published var token: String
    @Published var status = "Stopped"
    @Published var lastText = ""
    /// Recent phrases shown in the local transcript window (newest last).
    @Published var lines: [TranscriptLine] = []
    @Published var running = false
    @Published var listening = false
    @Published var devices: [InputDevice] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Set by the updater when an update is downloaded and waiting to relaunch the app.
    @Published var pendingUpdate: (() -> Void)?

    @Published var translationNote: String?
    @Published var languages: [TranslationLanguage] = []
    private let translator = Translator()
    private let engine = SpeechEngine()
    private let capture = AudioCapture()
    private var runTask: Task<Void, Never>?
    private var sender: Sender?
    private var heartbeatTask: Task<Void, Never>?

    let updates = UpdateManager()

    init() {
        (settings, token) = SettingsStore.load()
        refreshDevices()
        loadLanguages()
        updates.model = self
        // Resume after a reboot or an update (never pops the "key needed" alert on a fresh install).
        if settings.autoStart && !token.isEmpty { Task { @MainActor in self.start() } }
    }

    var statusDot: String? { listening ? "🔴" : (running ? "🟡" : nil) }

    var channelCount: Int {
        let ch = devices.first { $0.name == settings.device }?.channels ?? max(devices.first?.channels ?? 1, 1)
        return max(ch, settings.channel)
    }

    func refreshDevices() { devices = AudioDevices.inputs() }

    func start() {
        guard runTask == nil else { return }
        guard !token.isEmpty else {
            let a = NSAlert()
            a.messageText = "Transcriber key needed"
            a.informativeText = "Open “Website settings…” and enter the site address and this campus’s key (made in the website’s admin page) first."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        running = true
        status = "Starting…"
        runTask = Task { await self.run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        capture.stop()
        heartbeatTask?.cancel()
        sender?.stop()
        sender = nil
        running = false
        listening = false
        status = "Stopped"
        if let install = pendingUpdate { install() }  // an update was waiting for the service to finish
    }

    func toggle() { running ? stop() : start() }

    /// Called after a setting changes: save, and restart if running so it takes effect.
    func apply() {
        SettingsStore.save(settings, token: token)
        if running {
            stop()
            start()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { status = "Couldn't change Open at Login: \(error.localizedDescription)" }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Loads the languages the system can translate into (empty before macOS 26).
    func loadLanguages() {
        Task {
            languages = await Translator.supportedLanguages()
            checkTranslation()
        }
    }

    func toggleLanguage(_ code: String) {
        if let i = settings.translateTo.firstIndex(of: code) { settings.translateTo.remove(at: i) } else { settings.translateTo.append(code) }
        saveSettings()
        checkTranslation()
    }

    func saveSettings() { SettingsStore.save(settings, token: token) }

    /// Sets a note when a chosen language can't be used yet (nil when everything is ready).
    func checkTranslation() {
        Task {
            var missing: [String] = []
            for code in settings.translateTo where await translator.availability(of: code) != .ready { missing.append(code) }
            if settings.translateTo.isEmpty { translationNote = nil }
            else if languages.isEmpty { translationNote = "Translation needs macOS 26 or newer" }
            else if !missing.isEmpty {
                let names = missing.map { code in languages.first { $0.code == code }?.name ?? code }.joined(separator: ", ")
                translationNote = "Install \(names) in System Settings → General → Language & Region → Translation Languages"
            } else { translationNote = nil }
        }
    }

    private func show(_ text: String, translations: [String: String]) {
        lastText = text
        lines.append(TranscriptLine(text: text, translations: translations))
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func liveURL() -> URL? {
        let base = settings.url.components(separatedBy: "/api/transcript").first ?? settings.url
        if let c = sender?.campus { return URL(string: "\(base)/live/\(c)") }
        return URL(string: base)
    }

    // MARK: running

    private func run() async {
        do {
            if !(await engine.isLoaded) {
                try await engine.load(
                    progress: { p in Task { @MainActor in self.status = "Downloading speech model… \(Int(p * 100))%" } },
                    stage: { s in Task { @MainActor in self.status = s } })
            }
            guard await MicPermission.request() else {
                fail("Microphone access is off — allow it in System Settings → Privacy & Security → Microphone")
                return
            }
        } catch {
            fail("Error: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        let sender = Sender(url: settings.url, token: token) { s in Task { @MainActor in self.status = s } }
        self.sender = sender
        let (phrases, phraseSink) = AsyncStream.makeStream(of: [Float].self, bufferingPolicy: .bufferingNewest(8))  // falls behind -> drops oldest
        let corrections = settings.corrections
        let worker = Task {
            for await audio in phrases {
                if let text = try? await engine.text(for: audio, corrections: corrections), !text.isEmpty {
                    let (targets, forward) = await MainActor.run { (self.settings.translateTo, self.settings.sendTranslations) }
                    guard !targets.isEmpty else {
                        sender.send(text)
                        await MainActor.run { self.show(text, translations: [:]) }
                        continue
                    }
                    // Translate first so English and its translations reach the website together
                    // (a slow language is dropped after a few seconds, never holding up the service).
                    let translations = await translator.translate(text, to: targets)
                    sender.send(text, translations: forward ? translations : [:])
                    await MainActor.run { self.show(text, translations: translations) }
                }
            }
        }
        defer { phraseSink.finish(); worker.cancel() }

        heartbeatTask = Task {
            while !Task.isCancelled {
                if await MainActor.run(body: { self.listening }) { await sender.heartbeat() }
                try? await Task.sleep(for: .seconds(15))
            }
        }

        while !Task.isCancelled {
            if settings.scheduleOn && !Schedule.inWindow() {
                status = "Waiting for the schedule"
                while !Task.isCancelled && !Schedule.inWindow() { try? await Task.sleep(for: .seconds(1)) }
                continue
            }
            if await listenUntilDone(phraseSink) == false { return }
        }
    }

    /// Listens until stopped, the schedule window ends, or the audio setup changes. Returns false on a fatal error.
    private func listenUntilDone(_ sink: AsyncStream<[Float]>.Continuation) async -> Bool {
        let segmenter = Segmenter(minDb: settings.minDb)
        let queue = DispatchQueue(label: "audio.segment")
        let device = devices.first { $0.name == settings.device }
        let interrupted = Interrupt()
        do {
            try capture.start(device: device, channel: settings.channel,
                              onSamples: { samples in queue.async { segmenter.feed(samples: samples).forEach { sink.yield($0) } } },
                              onInterrupted: { interrupted.flag = true })
        } catch {
            fail("Error: \(error.localizedDescription)")
            return false
        }
        status = "Listening"
        listening = true
        while !Task.isCancelled && !interrupted.flag && !(settings.scheduleOn && !Schedule.inWindow()) {
            try? await Task.sleep(for: .seconds(1))
        }
        capture.stop()
        listening = false
        queue.sync { if let tail = segmenter.flush() { sink.yield(tail) } }
        if interrupted.flag && !Task.isCancelled {
            status = "Audio changed — reconnecting…"
            refreshDevices()
            try? await Task.sleep(for: .seconds(2))
        }
        return true
    }

    private func fail(_ message: String) {
        runTask = nil
        running = false
        listening = false
        heartbeatTask?.cancel()
        sender?.stop()
        sender = nil
        status = message
    }
}

struct TranscriptLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    var translations: [String: String] = [:]
}

private final class Interrupt: @unchecked Sendable { var flag = false }
