import Foundation
import Translation

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

/// On-device translation from English using Apple's Translation models (offline once a language is installed).
/// Needs macOS 26+ for sessions without a visible window; older systems report it as unavailable.
actor Translator {
    enum Availability { case ready, needsDownload, unavailable }

    private static let english = Locale.Language(identifier: "en")
    private var sessions: [String: Any] = [:]

    /// Every language the system can translate English into.
    static func supportedLanguages() async -> [TranslationLanguage] {
        guard #available(macOS 26, *) else { return [] }
        let all = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return all.compactMap { lang in
            guard lang.languageCode?.identifier != "en" else { return nil }
            let code = lang.minimalIdentifier
            guard seen.insert(code).inserted else { return nil }
            return TranslationLanguage(code: code, name: Locale.current.localizedString(forIdentifier: code) ?? code)
        }.sorted { $0.name < $1.name }
    }

    func availability(of code: String) async -> Availability {
        guard #available(macOS 26, *) else { return .unavailable }
        switch await LanguageAvailability().status(from: Self.english, to: Locale.Language(identifier: code)) {
        case .installed: return .ready
        case .supported: return .needsDownload
        default: return .unavailable
        }
    }

    /// Translates into every language at once; a language that fails or is too slow is just left out.
    func translate(_ text: String, to codes: [String], timeout: Duration = .seconds(4)) async -> [String: String] {
        guard #available(macOS 26, *), !codes.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { group in
            for code in codes {
                group.addTask { (code, await self.translateOne(text, to: code)) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return ("", nil)  // timeout marker
            }
            var out: [String: String] = [:]
            var pending = codes.count
            for await (code, result) in group {
                if code.isEmpty { break }  // timed out: give up on the rest
                if let result { out[code] = result }
                pending -= 1
                if pending == 0 { break }
            }
            group.cancelAll()
            return out
        }
    }

    private func translateOne(_ text: String, to code: String) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        do {
            let s: TranslationSession
            if let existing = sessions[code] as? TranslationSession { s = existing } else {
                s = TranslationSession(installedSource: Self.english, target: Locale.Language(identifier: code))
                sessions[code] = s
            }
            return try await s.translate(text).targetText
        } catch {
            sessions[code] = nil
            return nil
        }
    }
}
