import Foundation
import Security

let defaultCorrections = "LifePoint => Lifepoint\nLife Point => Lifepoint"

/// User settings. Everything except the key lives in UserDefaults; the key is in the Keychain.
struct Settings: Codable, Equatable {
    var url = "http://localhost:3000/api/transcript"
    var device: String?            // nil = system default
    var channel = 1
    var corrections = defaultCorrections  // one "heard => correct" per line, applied to every phrase
    var minDb = -50.0
    var scheduleOn = false
    var translateTo: [String] = []  // language codes translated on-device (shown locally, optionally sent)
    var sendTranslations = false    // also send the translations to the website for viewers to pick from
    var autoStart = true           // start listening when the app opens (survives updates and reboots)
}

extension Settings {
    /// Missing keys (settings saved by an older version) fall back to defaults instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? d.url
        device = try c.decodeIfPresent(String.self, forKey: .device)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? d.channel
        corrections = try c.decodeIfPresent(String.self, forKey: .corrections) ?? d.corrections
        minDb = try c.decodeIfPresent(Double.self, forKey: .minDb) ?? d.minDb
        scheduleOn = try c.decodeIfPresent(Bool.self, forKey: .scheduleOn) ?? d.scheduleOn
        translateTo = try c.decodeIfPresent([String].self, forKey: .translateTo) ?? d.translateTo
        sendTranslations = try c.decodeIfPresent(Bool.self, forKey: .sendTranslations) ?? d.sendTranslations
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
    }
}

enum Keychain {
    private static let service = "church.lifepoint.transcriber"
    private static let account = "transcriber-key"

    static func read() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func write(_ value: String) {
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
            s.device = j["device"] as? String
            s.channel = j["channel"] as? Int ?? s.channel
            s.minDb = j["min_db"] as? Double ?? s.minDb
            s.scheduleOn = j["schedule_on"] as? Bool ?? s.scheduleOn
            token = j["token"] as? String ?? ""
        }
        return (s, token)
    }
}
