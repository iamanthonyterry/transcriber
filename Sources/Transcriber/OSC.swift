import Foundation
import Network

/// "When this phrase is heard, send this OSC message."
struct OSCRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var phrase = ""
    var address = "/"
    var argument = ""  // empty = none; otherwise an int, a float, or a string (in that order of preference)
}

enum OSC {
    /// Rules whose phrase appears in `text` as whole words (ignores case and punctuation).
    static func matches(_ rules: [OSCRule], in text: String) -> [OSCRule] {
        let heard = " " + normalize(text) + " "
        return rules.filter {
            let p = normalize($0.phrase)
            return !p.isEmpty && $0.address.hasPrefix("/") && $0.address.count > 1 && heard.contains(" " + p + " ")
        }
    }

    private static func normalize(_ s: String) -> String {
        let kept = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// An OSC 1.0 message: padded address, type tag string, then the argument.
    static func encode(address: String, argument: String) -> Data {
        var data = padded(address)
        let arg = argument.trimmingCharacters(in: .whitespaces)
        if arg.isEmpty {
            data += padded(",")
        } else if let i = Int32(arg) {
            data += padded(",i") + be(UInt32(bitPattern: i))
        } else if let f = Float(arg) {
            data += padded(",f") + be(f.bitPattern)
        } else {
            data += padded(",s") + padded(arg)
        }
        return data
    }

    private static func padded(_ s: String) -> Data {
        var d = Data(s.utf8)
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    private static func be(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }
}

/// Fire-and-forget UDP sender (OSC is connectionless, so a dead receiver never blocks transcription).
final class OSCSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "osc.send")

    func send(_ rule: OSCRule, host: String, port: Int) {
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), !host.isEmpty else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .udp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: OSC.encode(address: rule.address, argument: rule.argument),
                          completion: .contentProcessed { _ in conn.cancel() })
            case .failed, .waiting:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }
}
