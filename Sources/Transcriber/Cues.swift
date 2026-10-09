import Foundation

/// Matching spoken phrases to rules. Speech is compared word by word after being tidied up, so
/// "Go queue twenty-five." matches the phrase "go cue {number}" with the number 25.
enum Cues {
    static let slot = "{number}"

    /// Words Whisper writes for the one that was meant.
    private static let sameWord = ["queue": "cue", "q": "cue", "queues": "cues", "que": "cue"]
    /// What a lone word means when a number is expected ("go cue two" is often written "go cue to").
    private static let soundsLikeNumber = ["to": "2", "too": "2", "for": "4", "fore": "4", "won": "1", "ate": "8"]

    private static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
                                "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// Lowercase words with punctuation dropped, the usual mis-hearings fixed, and numbers as digits
    /// ("twenty five" -> "25", "five point five" -> "5.5").
    static func words(_ text: String) -> [String] {
        let chars = Array(text.lowercased())
        var kept = ""
        for (i, c) in chars.enumerated() {
            let betweenDigits = c == "." && i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
            if i > 0, c.isNumber != chars[i - 1].isNumber, c.isLetter || c.isNumber, chars[i - 1].isLetter || chars[i - 1].isNumber { kept.append(" ") }  // "Q25" -> "q 25"
            kept.append(c.isLetter || c.isNumber || c == "{" || c == "}" || betweenDigits ? c : " ")
        }
        return digits(kept.split(separator: " ").map { sameWord[String($0)] ?? String($0) })
    }

    private static func digits(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            var number: String?
            if let (value, used) = spokenNumber(words, from: i) { number = String(value); i += used }
            else if Int(words[i]) != nil { number = words[i]; i += 1 }
            guard var n = number else { out.append(words[i]); i += 1; continue }
            // "point five" after a whole number
            if i + 1 < words.count, words[i] == "point" {
                var decimals = "", j = i + 1
                while j < words.count, let d = units[words[j]] ?? (words[j].count == 1 ? Int(words[j]) : nil) { decimals += String(d); j += 1 }
                if !decimals.isEmpty { n += "." + decimals; i = j }
            }
            out.append(n)
        }
        return out
    }

    /// A number written in words starting at `i` ("one hundred and five"): its value and how many words it took.
    private static func spokenNumber(_ w: [String], from i: Int) -> (Int, Int)? {
        enum Last { case none, unit, teen, tens, hundred, thousand }
        var total = 0, current = 0, last = Last.none, j = i
        loop: while j < w.count {
            let word = w[j]
            if let v = units[word] {
                guard last == .none || last == .tens || last == .hundred || last == .thousand, !(last == .none && j > i) else { break loop }
                current += v; last = .unit
            } else if let v = teens[word] ?? tens[word] {
                guard last == .none || last == .hundred || last == .thousand else { break loop }
                current += v; last = teens[word] != nil ? .teen : .tens
            } else if word == "hundred" {
                guard last == .unit || last == .teen, current > 0, current < 100 else { break loop }
                current *= 100; last = .hundred
            } else if word == "thousand" {
                guard last == .unit || last == .teen || last == .tens || last == .hundred, current > 0 else { break loop }
                total += current * 1000; current = 0; last = .thousand
            } else if word == "and", last == .hundred || last == .thousand, j + 1 < w.count,
                      units[w[j + 1]] != nil || teens[w[j + 1]] != nil || tens[w[j + 1]] != nil {
                // "one hundred and five": skip the "and"
            } else {
                break loop
            }
            j += 1
        }
        return j > i ? (total + current, j - i) : nil
    }

    /// What a commands-only input should expect to hear: the wake word and each rule's words. Whisper then
    /// writes "go cue 25" where it would otherwise write "GoQ25".
    static func vocabulary(_ rules: [OSCRule], wakeWord: String) -> String {
        ([wakeWord] + rules.filter(\.isSendable).map { $0.phrase.replacingOccurrences(of: slot, with: " ") })
            .map { $0.split(separator: " ").joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Every way `rules` occur in the heard words, each with the spoken number filled in.
    static func matches(_ rules: [OSCRule], in heard: [String]) -> [OSCRule] {
        var found: [OSCRule] = []
        for rule in rules where rule.isSendable {
            let pattern = words(rule.phrase)
            guard !pattern.isEmpty, pattern.contains(where: { $0 != slot }), heard.count >= pattern.count else { continue }
            for start in 0...(heard.count - pattern.count) {
                var number = ""
                let fits = pattern.indices.allSatisfy { k in
                    let word = heard[start + k]
                    guard pattern[k] == slot else { return pattern[k] == word }
                    guard let n = Double(word) != nil ? word : soundsLikeNumber[word] else { return false }
                    number = n
                    return true
                }
                if fits {
                    let filled = pattern.contains(slot) ? rule.filled(with: number) : rule
                    if !found.contains(filled) { found.append(filled) }
                }
            }
        }
        return found
    }
}

/// What happened to a rule whose phrase was heard.
struct CueEvent: Identifiable {
    enum Outcome { case sent, cooldown, noWakeWord }
    let id = UUID()
    let date: Date
    let rule: OSCRule  // with the spoken number filled in
    let outcome: Outcome
}

/// Decides which heard rules may actually fire, so talk that merely contains a phrase doesn't run a cue.
/// With a wake word, a rule fires only right after it: in the same phrase, or in the next one within a few
/// seconds (people pause after the wake word). One wake word allows one phrase of cues. A cue that just
/// fired is held off for the cooldown, so an echo or a repeated word can't fire it twice.
struct CueGuard {
    static let wakeSeconds = 8.0
    private var awakeUntil = Date.distantPast
    private var lastSent: [String: Date] = [:]

    mutating func check(_ text: String, rules: [OSCRule], wakeWord: String, cooldown: Double, now: Date = Date()) -> [CueEvent] {
        var heard = Cues.words(text)
        let wake = Cues.words(wakeWord)
        var awake = wake.isEmpty || now < awakeUntil
        if !wake.isEmpty, heard.count >= wake.count,
           let at = (0...(heard.count - wake.count)).last(where: { Array(heard[$0..<$0 + wake.count]) == wake }) {
            heard = Array(heard[(at + wake.count)...])  // only what follows the wake word counts
            awake = true
            awakeUntil = now.addingTimeInterval(Self.wakeSeconds)
        }
        let events = Cues.matches(rules, in: heard).map { rule -> CueEvent in
            // "go cue 5" then "go cue 6" are different cues: the cooldown is per message, not per rule
            let key = "\(rule.id) \(rule.address) \(rule.argument)"
            if !awake { return CueEvent(date: now, rule: rule, outcome: .noWakeWord) }
            if let last = lastSent[key], now.timeIntervalSince(last) < cooldown { return CueEvent(date: now, rule: rule, outcome: .cooldown) }
            lastSent[key] = now
            return CueEvent(date: now, rule: rule, outcome: .sent)
        }
        if events.contains(where: { $0.outcome == .sent }) { awakeUntil = .distantPast }
        return events
    }
}
