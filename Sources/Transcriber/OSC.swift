import Foundation
import Network

/// "When this phrase is heard, send this": an OSC message, a web request or a MIDI message.
/// The phrase may contain `{number}` ("go cue {number}"), and so may the address and value, which get
/// the number that was said ("/cue/{number}/start").
struct OSCRule: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case osc, httpGet, httpPost, midi }

    var id = UUID()
    var phrase = ""
    var kind = Kind.osc
    var address = "/"      // OSC address; or a URL; or a MIDI message: "note 60", "cc 20", "program 5" (add "ch 2" for a channel)
    var argument = ""      // OSC: empty = none, else an int, a float or a string. HTTP POST: the body. MIDI: velocity or value.
    var destination = ""   // OSC only: "host" or "host:port" for this rule (empty = the default)

    init(id: UUID = UUID(), phrase: String = "", kind: Kind = .osc, address: String = "/", argument: String = "", destination: String = "") {
        (self.id, self.phrase, self.kind, self.address, self.argument, self.destination) = (id, phrase, kind, address, argument, destination)
    }

    /// Missing keys (rules saved by an older version) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phrase = try c.decodeIfPresent(String.self, forKey: .phrase) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .osc
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? "/"
        argument = try c.decodeIfPresent(String.self, forKey: .argument) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
    }

    /// Whether there is something sendable here (an unfinished rule never fires).
    var isSendable: Bool {
        let filled = address.replacingOccurrences(of: Cues.slot, with: "1")
        switch kind {
        case .osc: return filled.hasPrefix("/") && filled.count > 1
        case .httpGet, .httpPost: return URL(string: filled).map { ["http", "https"].contains($0.scheme ?? "") && $0.host != nil } ?? false
        case .midi: return MIDIMessage(filled, value: "") != nil
        }
    }

    /// This rule with the spoken number put into its address and value.
    func filled(with number: String) -> OSCRule {
        var r = self
        r.address = address.replacingOccurrences(of: Cues.slot, with: number)
        r.argument = argument.replacingOccurrences(of: Cues.slot, with: number)
        return r
    }
}

enum OSC {
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

extension OSC {
    /// "host" or "host:port" -> where to send, falling back to the defaults for whatever is left out.
    static func destination(_ text: String, host: String, port: Int) -> (host: String, port: Int) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return (host, port) }
        if let colon = t.lastIndex(of: ":"), let p = Int(t[t.index(after: colon)...]) {
            let h = String(t[..<colon])
            return (h.isEmpty ? host : h, p)
        }
        return (t, port)
    }

    /// Reads an incoming OSC message: its address and its arguments (ints, floats, strings, true/false).
    static func decode(_ message: Data) -> (address: String, arguments: [String])? {
        let data = [UInt8](message)
        var i = 0
        func string() -> String? {
            guard i < data.count, let end = data[i...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: data[i..<end], as: UTF8.self)
            i = (end + 4) / 4 * 4  // strings are padded to four bytes
            return s
        }
        func word() -> UInt32? {
            guard i + 4 <= data.count else { return nil }
            defer { i += 4 }
            return data[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard let address = string(), address.hasPrefix("/") else { return nil }
        var arguments: [String] = []
        for tag in (string() ?? ",").dropFirst() {
            switch tag {
            case "i": guard let w = word() else { return nil }; arguments.append(String(Int32(bitPattern: w)))
            case "f": guard let w = word() else { return nil }; arguments.append(String(Float(bitPattern: w)))
            case "s": guard let s = string() else { return nil }; arguments.append(s)
            case "T": arguments.append("1")
            case "F": arguments.append("0")
            default: return (address, arguments)  // a type we don't read: keep what we have
            }
        }
        return (address, arguments)
    }
}

/// Carries out a rule: OSC over UDP, a web request, or MIDI. Nothing here waits or blocks.
final class CueSender: @unchecked Sendable {
    private let osc = OSCSender()
    private let midi = MIDIOut()

    /// Makes the "Transcriber" MIDI source appear if any rule needs it, so the receiving app can pick it beforehand.
    func prepare(_ rules: [OSCRule]) {
        if rules.contains(where: { $0.kind == .midi }) { midi.open() }
    }

    func send(_ rule: OSCRule, host: String, port: Int) {
        switch rule.kind {
        case .osc:
            let to = OSC.destination(rule.destination, host: host, port: port)
            osc.send(rule, host: to.host, port: to.port)
        case .httpGet, .httpPost:
            guard let url = URL(string: rule.address) else { return }
            var request = URLRequest(url: url, timeoutInterval: 5)
            if rule.kind == .httpPost {
                request.httpMethod = "POST"
                request.httpBody = Data(rule.argument.utf8)
                let json = rule.argument.trimmingCharacters(in: .whitespaces).first.map { $0 == "{" || $0 == "[" } ?? false
                if !rule.argument.isEmpty { request.setValue(json ? "application/json" : "text/plain", forHTTPHeaderField: "Content-Type") }
            }
            URLSession.shared.dataTask(with: request).resume()
        case .midi:
            if let message = MIDIMessage(rule.address, value: rule.argument) { midi.send(message) }
        }
    }
}

/// Listens for OSC on a UDP port so a cue list or a button box can run the transcriber.
final class OSCListener: @unchecked Sendable {
    private var listener: NWListener?
    private(set) var port = 0

    /// `handler` is called on the main actor with each message. Port 0 (or one that can't be opened) just stops listening.
    func start(port: Int, handler: @escaping @MainActor (String, [String]) -> Void) {
        stop()
        guard port > 0, let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), let l = try? NWListener(using: .udp, on: p) else { return }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            @Sendable func receive() {
                conn.receiveMessage { data, _, _, error in
                    if let data, let m = OSC.decode(data) { Task { @MainActor in handler(m.address, m.arguments) } }
                    if error == nil { receive() } else { conn.cancel() }
                }
            }
            receive()
        }
        l.start(queue: .global())
        listener = l
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }
}
