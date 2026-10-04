import AppKit
import Network
import Security

/// Signs in through the website, the same way the admin does, and gets back the key for the campus the admin picks.
/// The browser opens the site's connect page; when the admin chooses a campus the site redirects to a one-shot
/// listener on this Mac's loopback address (127.0.0.1 only), which receives the key and then closes.
final class WebSignIn: @unchecked Sendable {
    struct Connection {
        let key: String
        let church: String
        let campus: String
        let name: String
    }

    enum Failure: LocalizedError {
        case timedOut, badSite, listener(String)
        var errorDescription: String? {
            switch self {
            case .timedOut: "Sign-in wasn't finished in time. Try again."
            case .badSite: "The website address isn't valid."
            case .listener(let m): "Couldn't start sign-in (\(m))."
            }
        }
    }

    private let queue = DispatchQueue(label: "church.lifepoint.transcriber.signin")
    private let state: String = {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Connection, Error>?
    private var done = false

    /// Opens the browser at `site` (the website's origin) and waits for the admin to pick a campus.
    func run(site: String) async throws -> Connection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async { self.begin(site: site, cont) }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func begin(site: String, _ cont: CheckedContinuation<Connection, Error>) {
        guard !done else { return cont.resume(throwing: CancellationError()) }
        continuation = cont
        guard let base = URL(string: site), base.scheme == "https" || base.scheme == "http", base.host != nil else {
            return finish(.failure(Failure.badSite))
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)  // never reachable from the network
        guard let listener = try? NWListener(using: params) else { return finish(.failure(Failure.listener("no port available"))) }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                guard let port = listener.port?.rawValue,
                      var c = URLComponents(url: base.appendingPathComponent("auth/transcriber"), resolvingAgainstBaseURL: false) else { return }
                c.queryItems = [URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "state", value: self.state)]
                if let url = c.url { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            case .failed(let e):
                self.finish(.failure(Failure.listener(e.localizedDescription)))
            default: break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(.failure(Failure.timedOut)) }
    }

    private func finish(_ result: Result<Connection, Error>) {
        guard !done else { return }
        done = true
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data else { return conn.cancel() }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/callback" else {
                return self.reply(conn, status: "404 Not Found", body: "Not found")
            }
            func item(_ n: String) -> String { c.queryItems?.first { $0.name == n }?.value ?? "" }
            let key = item("key")
            guard item("state") == self.state, key.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil, !item("campus").isEmpty else {
                return self.reply(conn, status: "400 Bad Request", body: "This sign-in link isn't valid. Start again from the Transcriber app.")
            }
            let name = item("name")
            self.reply(conn, status: "200 OK", body: "<h2>Connected to \(Self.escape(name.isEmpty ? item("campus") : name))</h2><p>You can close this tab and return to Transcriber.</p>")
            self.finish(.success(Connection(key: key, church: item("church"), campus: item("campus"), name: name)))
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        // The address bar holds the key until replaced, so swap it out of the browser's history right away.
        let html = "<!doctype html><meta charset=utf-8><title>Transcriber</title><script>history.replaceState(null,'','/done')</script>"
            + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\">\(body)</body>"
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
