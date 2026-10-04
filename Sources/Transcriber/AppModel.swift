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
    /// Every phrase of the current session (survives "Clear"); saved and reset when the session ends.
    private(set) var sessionLog: [TranscriptLine] = []
    private var sessionStart = Date()
    private var restarting = false
    @Published var running = false
    @Published var listening = false
    @Published var devices: [InputDevice] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Set by the updater when an update is downloaded and waiting to relaunch the app.
    @Published var pendingUpdate: (() -> Void)?

    @Published var translationNote: String?
    @Published var languages: [TranslationLanguage] = []
    /// Languages waiting for the system's download prompt, one at a time.
    @Published var downloadQueue: [String] = []
    @Published var signInBusy = false
    @Published var signInError: String?
    private var signInTask: Task<Void, Never>?
    @Published var pcoSignedIn = false
    @Published var pcoTypes: [PCOServiceType] = []
    @Published var pcoBusy = false
    @Published var pcoError: String?
    private let pco = PCOClient()
    private let translator = Translator()
    private let engine = SpeechEngine()
    private let capture = AudioCapture()
    private let meterCapture = AudioCapture()
    private let levelCheck = LevelCheck()
    @Published var checkingLevel = false
    @Published var levelResult: LevelCheckResult?
    /// Current input level in dB (about -90 when silent or not listening), shown in Settings.
    @Published var levelDb: Double = -90
    private var runTask: Task<Void, Never>?
    private var sender: Sender?
    private var heartbeatTask: Task<Void, Never>?

    let updates = UpdateManager()

    init() {
        (settings, token) = SettingsStore.load()
        refreshDevices()
        loadLanguages()
        updates.model = self
        Task { @MainActor in await self.pcoStartup() }
        // Resume after a reboot or an update (never pops the "key needed" alert on a fresh install).
        if settings.autoStart && !token.isEmpty { Task { @MainActor in self.start() } }
    }

    var statusTint: NSColor? { listening ? .systemRed : (running ? .systemYellow : nil) }

    var channelCount: Int {
        let ch = devices.first { $0.name == settings.device }?.channels ?? max(devices.first?.channels ?? 1, 1)
        return max(ch, settings.channel)
    }

    func refreshDevices() { devices = AudioDevices.inputs() }

    func start() {
        guard runTask == nil else { return }
        stopMeter()
        guard !token.isEmpty else {
            let a = NSAlert()
            a.messageText = "Sign in to the website first"
            a.informativeText = "Open “Website settings…” and sign in with the website to choose which campus this Mac sends to."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        if !restarting { beginSession() }
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
        if !restarting { endSession() }
        if let install = pendingUpdate { install() }  // an update was waiting for the service to finish
    }

    /// Settings' level meter: while transcribing it reads the live capture, otherwise it listens on its own.
    func startMeter() {
        guard !running else { return }
        Task { @MainActor in
            guard !self.running, await MicPermission.request(), !self.running else { return }
            let reporter = LevelReporter { db in Task { @MainActor in self.levelDb = db } }
            let device = self.devices.first { $0.name == self.settings.device }
            try? self.meterCapture.start(device: device, channel: self.settings.channel,
                                         onSamples: { reporter.feed($0); self.levelCheck.feed($0) }, onInterrupted: {})
        }
    }

    func stopMeter() {
        meterCapture.stop()
        if !running { levelDb = -90 }
    }

    /// Listens for a few seconds (on the live capture if transcribing, else on its own) and judges the level.
    func checkLevel() {
        guard !checkingLevel else { return }
        checkingLevel = true
        levelResult = nil
        levelCheck.begin()
        startMeter()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            self.levelResult = self.levelCheck.finish()
            self.checkingLevel = false
        }
    }

    func toggle() { running ? stop() : start() }

    /// Called after a setting changes: save, and restart if running so it takes effect.
    /// The website's address without the API path (the same site the key belongs to).
    var siteBase: String { settings.url.components(separatedBy: "/api/transcript").first ?? settings.url }

    /// Signs in through the website in the browser, then uses the campus the admin picks there.
    func signInWithWebsite() {
        guard signInTask == nil else { return }
        signInBusy = true
        signInError = nil
        signInTask = Task { @MainActor in
            defer { signInBusy = false; signInTask = nil }
            do {
                let c = try await WebSignIn().run(site: siteBase)
                token = c.key
                settings.connectedTo = c.name.isEmpty ? c.campus : c.name
                apply()
                NSApp.activate(ignoringOtherApps: true)
            } catch is CancellationError {
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    func cancelSignIn() { signInTask?.cancel() }

    func disconnect() {
        token = ""
        settings.connectedTo = ""
        if running { stop() }
        SettingsStore.save(settings, token: token)
    }

    func apply() {
        SettingsStore.save(settings, token: token)
        if running {
            restarting = true  // a settings change must not split the session
            stop()
            start()
            restarting = false
        }
    }

    // MARK: Planning Center

    /// Picks up a saved sign-in, then keeps the service times fresh while Planning Center scheduling is on.
    private func pcoStartup() async {
        pcoSignedIn = await pco.signedIn
        if pcoSignedIn { await loadPCOTypes() }
        while !Task.isCancelled {
            if settings.pcoOn && pcoSignedIn { await refreshPCOTimes() }
            try? await Task.sleep(for: .seconds(30 * 60))
        }
    }

    func pcoSignIn() {
        guard !pcoBusy else { return }
        pcoBusy = true
        pcoError = nil
        Task {
            do {
                try await pco.signIn()
                pcoSignedIn = true
                await loadPCOTypes()
            } catch { pcoError = error.localizedDescription }
            pcoBusy = false
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func pcoSignOut() {
        Task {
            await pco.signOut()
            pcoSignedIn = false
            pcoTypes = []
            settings.pcoOn = false  // back to the manual times
            settings.pcoServiceTypeID = nil
            settings.pcoServiceTypeName = ""
            settings.pcoTimes = []
            saveSettings()
        }
    }

    func loadPCOTypes() async {
        do { pcoTypes = try await pco.serviceTypes(); pcoError = nil } catch { handlePCO(error) }
    }

    func selectPCOType(_ id: String?) {
        settings.pcoServiceTypeID = id
        settings.pcoServiceTypeName = pcoTypes.first { $0.id == id }?.name ?? ""
        settings.pcoTimes = []
        saveSettings()
        Task { await refreshPCOTimes() }
    }

    func refreshPCOTimes() async {
        guard let id = settings.pcoServiceTypeID else { return }
        pcoBusy = true
        defer { pcoBusy = false }
        do {
            settings.pcoTimes = try await pco.serviceTimes(typeID: id)  // the cached times stay if this fails
            pcoError = nil
            saveSettings()
        } catch { handlePCO(error) }
    }

    private func handlePCO(_ error: Error) {
        pcoError = error.localizedDescription
        if case PCOError.notSignedIn = error { pcoSignedIn = false }
    }

    // MARK: session transcript

    /// Set when a session begins; the next chance we get, the website is told to clear the old text.
    private var resetPending = false

    private func beginSession() {
        resetPending = true
        sessionLog = []
        lines = []
        lastText = ""
        sessionStart = Date()
    }

    /// Ends the session, saving a copy if asked, and returns where it was saved.
    @discardableResult
    func endSession() -> URL? {
        defer { sessionLog = [] }
        guard settings.saveCopy, !settings.saveFolder.isEmpty else { return nil }
        return saveTranscript(to: URL(fileURLWithPath: settings.saveFolder, isDirectory: true))
    }

    /// Writes the session so far as a text file in `folder` (used at session end and by "Save transcript now").
    @discardableResult
    func saveTranscript(to folder: URL) -> URL? {
        guard !sessionLog.isEmpty else { return nil }
        let name = "Transcript \(sessionStart.formatted(.iso8601.year().month().day())) \(sessionStart.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()).replacingOccurrences(of: ":", with: "."))"
        var url = folder.appendingPathComponent(name + ".txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(name) \(n).txt"); n += 1 }
        var out = ""
        for line in sessionLog {
            out += line.text + "\n"
            for code in settings.translateTo { if let t = line.translations[code] { out += "  [\(code)] \(t)\n" } }
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try out.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            status = "Couldn't save transcript: \(error.localizedDescription)"
            return nil
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
        if let i = settings.translateTo.firstIndex(of: code) {
            settings.translateTo.remove(at: i)
            downloadQueue.removeAll { $0 == code }
        } else {
            settings.translateTo.append(code)
            Task {
                // macOS shows its own download prompt for a language that isn't installed yet
                if await translator.availability(of: code) == .needsDownload, !downloadQueue.contains(code) { downloadQueue.append(code) }
            }
        }
        saveSettings()
        checkTranslation()
    }

    /// Called when the system's download prompt for the first queued language is done (installed or cancelled).
    func finishDownload() {
        if !downloadQueue.isEmpty { downloadQueue.removeFirst() }
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
        let line = TranscriptLine(text: text, translations: translations)
        lines.append(line)
        sessionLog.append(line)
    }

    func liveURL() -> URL? {
        let base = siteBase
        if let c = sender?.campus {
            // Pages live under the church's slug; older sites don't send one, and /live/<campus> redirects there.
            let path = sender?.church.map { "/\($0)/live/\(c)" } ?? "/live/\(c)"
            return URL(string: base + path)
        }
        return URL(string: base)
    }

    // MARK: running

    private func sendResetIfNeeded(_ sender: Sender) async {
        guard resetPending else { return }
        resetPending = false
        await sender.reset()
    }

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
        await sendResetIfNeeded(sender)
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
            if settings.scheduleOn && !Schedule.inWindow(settings) {
                status = "Waiting for the schedule"
                while !Task.isCancelled && !(settings.scheduleOn ? Schedule.inWindow(settings) : true) { try? await Task.sleep(for: .seconds(1)) }
                if !Task.isCancelled {  // a new window is a new transcript
                    beginSession()
                    await sendResetIfNeeded(sender)
                }
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
        let reporter = LevelReporter { db in Task { @MainActor in self.levelDb = db } }
        do {
            try capture.start(device: device, channel: settings.channel,
                              onSamples: { samples in
                                  reporter.feed(samples)
                                  self.levelCheck.feed(samples)
                                  queue.async { segmenter.feed(samples: samples).forEach { sink.yield($0) } }
                              },
                              onInterrupted: { interrupted.flag = true })
        } catch {
            fail("Error: \(error.localizedDescription)")
            return false
        }
        status = "Listening"
        listening = true
        while !Task.isCancelled && !interrupted.flag && !(settings.scheduleOn && !Schedule.inWindow(settings)) {
            try? await Task.sleep(for: .seconds(1))
        }
        let windowEnded = settings.scheduleOn && !Schedule.inWindow(settings)
        capture.stop()
        listening = false
        levelDb = -90
        queue.sync { if let tail = segmenter.flush() { sink.yield(tail) } }
        if windowEnded && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))  // let the last phrase finish transcribing
            if let saved = endSession() { status = "Saved \(saved.lastPathComponent)" }
        }
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
