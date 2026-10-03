import Foundation

/// Posts text to the website without ever blocking transcription. If the internet or the site is down,
/// text waits (newest 300 kept) and is resent in order once it is reachable again.
final class Sender: @unchecked Sendable {
    private let url: URL?
    private let token: String
    private let dryRun: Bool
    private let onStatus: @Sendable (String) -> Void
    private let stream: AsyncStream<Outgoing>
    private let continuation: AsyncStream<Outgoing>.Continuation
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var _campus: String?
    private var _church: String?
    private var bad = false

    var campus: String? { lock.withLock { _campus } }
    var church: String? { lock.withLock { _church } }

    init(url: String, token: String, dryRun: Bool = false, onStatus: @escaping @Sendable (String) -> Void) {
        self.url = URL(string: url)
        self.token = token
        self.dryRun = dryRun
        self.onStatus = onStatus
        (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self, bufferingPolicy: .bufferingNewest(300))
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        continuation.finish()
    }

    struct Outgoing: Sendable {
        let text: String
        var translations: [String: String] = [:]  // language code -> text
    }

    func send(_ text: String, translations: [String: String] = [:]) {
        continuation.yield(Outgoing(text: text, translations: translations))
    }

    /// Tells the website this campus is live. Best effort; never queued.
    func heartbeat() async {
        guard !dryRun else { return }
        do {
            try await post(nil)
            if bad {
                bad = false
                onStatus("Listening")
            }
        } catch let SendError.http(code) where code == 400 || code == 401 {
            bad = true
            onStatus("Website rejected us — check the key in Website settings")
        } catch {
            bad = true
            onStatus("Can't reach the website — check the address in Website settings")
        }
    }

    private enum SendError: Error { case http(Int), badURL }

    private func post(_ text: String?, translations: [String: String] = [:]) async throws {
        guard let url else { throw SendError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = text.map { ["text": $0] } ?? ["heartbeat": true]
        if !translations.isEmpty { body["translations"] = translations }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, res) = try await URLSession.shared.data(for: req)
        let code = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SendError.http(code) }
        if text == nil, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let c = j["campus"] as? String {
            lock.withLock {
                _campus = c
                _church = j["church"] as? String
            }
        }
    }

    private func run() async {
        var warned = false
        for await item in stream {
            if dryRun { continue }
            var delay = 1.0
            while !Task.isCancelled {
                do {
                    try await post(item.text, translations: item.translations)
                    if warned {
                        warned = false
                        onStatus("Listening")
                    }
                    break
                } catch let SendError.http(code) where code == 400 || code == 401 {
                    break  // retrying won't help; drop it (the heartbeat tells the user why)
                } catch {
                    if !warned {
                        warned = true
                        onStatus("Listening (website unreachable — retrying)")
                    }
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 15)
                }
            }
        }
    }
}
