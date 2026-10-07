import Foundation
import Security

let defaultCorrections = "LifePoint => Lifepoint\nLife Point => Lifepoint"

/// User settings. Everything except the key lives in UserDefaults; the key is in the Keychain.
struct Settings: Codable, Equatable {
    var url = "https://churchlandingpage.rosesashumans.com/api/transcript"
    var connectedTo = ""           // "Church · Campus" shown after signing in through the website (empty = key typed by hand)
    var inputs = [AudioInput()]    // every audio input being listened to
    var corrections = defaultCorrections  // one "heard => correct" per line, applied to every phrase
    var minDb = -50.0
    var scheduleOn = false
    var scheduleWindows = [ScheduleWindow()]  // listens during any of these
    var saveCopy = false               // write the whole transcript to saveFolder when a session ends
    var saveFolder = ""
    var translateTo: [String] = []  // language codes translated on-device (shown locally, optionally sent)
    var sendTranslations = false    // also send the translations to the website for viewers to pick from
    var autoStart = true           // start listening when the app opens (survives updates and reboots)
    var pcoOn = false              // schedule from Planning Center service times instead of the manual windows
    var pcoServiceTypeID: String?
    var pcoServiceTypeName = ""
    var pcoLeadMinutes = 15        // start listening this long before a service time
    var pcoLengthMinutes = 90      // and keep listening this long after it starts
    var pcoTimes: [Date] = []      // upcoming service start times (cached so it still works offline)
    var oscHost = "127.0.0.1"      // where OSC messages go (QLab, ProPresenter, a lighting desk…)
    var oscPort = 53000
    var oscRules: [OSCRule] = []   // phrase -> OSC message
}

/// One audio input (a device and one of its channels) and what its speech is used for.
struct AudioInput: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var device: String?       // nil = system default
    var channel = 1
    var sendToSite = true     // transcript goes to the website and the local window
    var triggerOSC = false    // phrases heard here fire the OSC rules
}

/// One recurring listening window: chosen weekdays between a start and end time (minutes after midnight).
struct ScheduleWindow: Codable, Equatable, Identifiable {
    var id = UUID()
    var days: Set<Int> = [1]  // Calendar weekdays, 1 = Sunday (repeats weekly)
    var date: Date?           // set = a one-off on that calendar day instead of repeating
    var start = 8 * 60
    var end = 12 * 60 + 30
}

private enum LegacyKeys: String, CodingKey { case scheduleDays, scheduleStart, scheduleEnd, device, channel, oscDevices }

extension Settings {
    /// Missing keys (settings saved by an older version) fall back to defaults instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        connectedTo = try c.decodeIfPresent(String.self, forKey: .connectedTo) ?? d.connectedTo
        if let list = try c.decodeIfPresent([AudioInput].self, forKey: .inputs), !list.isEmpty {
            inputs = list
        } else if let old = try? decoder.container(keyedBy: LegacyKeys.self) {
            // older versions had a single input
            let device = try old.decodeIfPresent(String.self, forKey: .device)
            let osc = try old.decodeIfPresent([String].self, forKey: .oscDevices) ?? []
            inputs = [AudioInput(device: device, channel: try old.decodeIfPresent(Int.self, forKey: .channel) ?? 1,
                                 triggerOSC: osc.contains(device ?? ""))]
        }
        corrections = try c.decodeIfPresent(String.self, forKey: .corrections) ?? d.corrections
        minDb = try c.decodeIfPresent(Double.self, forKey: .minDb) ?? d.minDb
        scheduleOn = try c.decodeIfPresent(Bool.self, forKey: .scheduleOn) ?? d.scheduleOn
        if let w = try c.decodeIfPresent([ScheduleWindow].self, forKey: .scheduleWindows) {
            scheduleWindows = w
        } else if let old = try? decoder.container(keyedBy: LegacyKeys.self), let days = try old.decodeIfPresent(Set<Int>.self, forKey: .scheduleDays) {
            // 2.1 saved a single window
            scheduleWindows = [ScheduleWindow(days: days,
                                              start: try old.decodeIfPresent(Int.self, forKey: .scheduleStart) ?? 480,
                                              end: try old.decodeIfPresent(Int.self, forKey: .scheduleEnd) ?? 750)]
        }
        saveCopy = try c.decodeIfPresent(Bool.self, forKey: .saveCopy) ?? d.saveCopy
        saveFolder = try c.decodeIfPresent(String.self, forKey: .saveFolder) ?? d.saveFolder
        translateTo = try c.decodeIfPresent([String].self, forKey: .translateTo) ?? d.translateTo
        sendTranslations = try c.decodeIfPresent(Bool.self, forKey: .sendTranslations) ?? d.sendTranslations
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        pcoOn = try c.decodeIfPresent(Bool.self, forKey: .pcoOn) ?? d.pcoOn
        pcoServiceTypeID = try c.decodeIfPresent(String.self, forKey: .pcoServiceTypeID)
        pcoServiceTypeName = try c.decodeIfPresent(String.self, forKey: .pcoServiceTypeName) ?? d.pcoServiceTypeName
        pcoLeadMinutes = try c.decodeIfPresent(Int.self, forKey: .pcoLeadMinutes) ?? d.pcoLeadMinutes
        pcoLengthMinutes = try c.decodeIfPresent(Int.self, forKey: .pcoLengthMinutes) ?? d.pcoLengthMinutes
        pcoTimes = try c.decodeIfPresent([Date].self, forKey: .pcoTimes) ?? d.pcoTimes
        oscHost = try c.decodeIfPresent(String.self, forKey: .oscHost) ?? d.oscHost
        oscPort = try c.decodeIfPresent(Int.self, forKey: .oscPort) ?? d.oscPort
        oscRules = try c.decodeIfPresent([OSCRule].self, forKey: .oscRules) ?? d.oscRules
    }
}

enum Keychain {
    private static let service = "church.lifepoint.transcriber"
    private static let defaultAccount = "transcriber-key"

    static func read(account: String = defaultAccount) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, account: String = defaultAccount) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum SettingsStore {
    private static let key = "settings.v1"

    static func load() -> (Settings, String) {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Settings.self, from: d) {
            return (s, Keychain.read())
        }
        return importLegacy()
    }

    static func save(_ s: Settings, token: String) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
        Keychain.write(token)
    }

    /// First launch: pick up the old Python app's config so a Mac that was already set up keeps working.
    private static func importLegacy() -> (Settings, String) {
        var s = Settings()
        var token = ""
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LifepointTranscriber/config.json")
        if let d = try? Data(contentsOf: path), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            s.url = j["url"] as? String ?? s.url
            s.inputs = [AudioInput(device: j["device"] as? String, channel: j["channel"] as? Int ?? 1)]
            s.minDb = j["min_db"] as? Double ?? s.minDb
            s.scheduleOn = j["schedule_on"] as? Bool ?? s.scheduleOn
            token = j["token"] as? String ?? ""
        }
        return (s, token)
    }
}
