import AppKit
import Foundation
import Network

/// Planning Center OAuth app credentials. build_app.sh puts them in Info.plist from Support/pco.env;
/// `swift run` can use the PCO_CLIENT_ID / PCO_CLIENT_SECRET environment variables instead.
enum PCOConfig {
    static let port: UInt16 = 53682
    static var redirectURI: String { "http://127.0.0.1:\(port)/callback" }
    static var clientID: String { value("PCOClientID", env: "PCO_CLIENT_ID") }
    static var clientSecret: String { value("PCOClientSecret", env: "PCO_CLIENT_SECRET") }
    static var isConfigured: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    private static func value(_ plistKey: String, env: String) -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String ?? ProcessInfo.processInfo.environment[env] ?? ""
        return v.hasPrefix("__") ? "" : v  // an unfilled __PLACEHOLDER__ means no credentials were built in
    }
}

enum PCOError: LocalizedError {
    case notConfigured, notSignedIn, cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "This build has no Planning Center credentials."
        case .notSignedIn: "Sign in to Planning Center again."
        case .cancelled: "Sign-in was cancelled or timed out."
        case .failed(let m): m
        }
    }
}

struct PCOServiceType: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct PCOTokens: Codable {
    var access: String
    var refresh: String
    var expires: Date
}

/// Signs in with Planning Center (OAuth in the browser) and reads service types and plan times.
actor PCOClient {
    private static let base = "https://api.planningcenteronline.com"
    private static let account = "pco-tokens"
    private var tokens: PCOTokens?

    init() {
        tokens = try? JSONDecoder().decode(PCOTokens.self, from: Data(Keychain.read(account: Self.account).utf8))
    }

    var signedIn: Bool { tokens != nil }

    func signOut() {
        tokens = nil
        Keychain.write("", account: Self.account)
    }

    // MARK: sign in

    func signIn() async throws {
        guard PCOConfig.isConfigured else { throw PCOError.notConfigured }
        let state = UUID().uuidString
        var authorize = URLComponents(string: "\(Self.base)/oauth/authorize")!
        authorize.queryItems = [.init(name: "client_id", value: PCOConfig.clientID), .init(name: "redirect_uri", value: PCOConfig.redirectURI),
                        .init(name: "response_type", value: "code"), .init(name: "scope", value: "services"), .init(name: "state", value: state)]
        let url = authorize.url!
        async let code = LoopbackServer.waitForCode(port: PCOConfig.port, state: state, timeout: 180)
        try await Task.sleep(for: .milliseconds(200))  // let the listener come up before the browser can call back
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        let t = try await tokenRequest(["grant_type": "authorization_code", "code": try await code, "redirect_uri": PCOConfig.redirectURI])
        store(t)
    }

    private func store(_ t: PCOTokens) {
        tokens = t
        if let d = try? JSONEncoder().encode(t) { Keychain.write(String(decoding: d, as: UTF8.self), account: Self.account) }
    }

    private func tokenRequest(_ params: [String: String]) async throws -> PCOTokens {
        var all = params
        all["client_id"] = PCOConfig.clientID
        all["client_secret"] = PCOConfig.clientSecret
        var req = URLRequest(url: URL(string: "\(Self.base)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        struct Body: Decodable { var access_token: String; var refresh_token: String; var expires_in: Int }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let b = try? JSONDecoder().decode(Body.self, from: data) else {
            throw PCOError.failed("Planning Center refused the sign-in.")
        }
        return PCOTokens(access: b.access_token, refresh: b.refresh_token, expires: Date().addingTimeInterval(Double(b.expires_in)))
    }

    private func refresh() async throws {
        guard let old = tokens else { throw PCOError.notSignedIn }
        do {
            store(try await tokenRequest(["grant_type": "refresh_token", "refresh_token": old.refresh]))
        } catch is PCOError {
            signOut()  // the refresh token no longer works; the user has to sign in again
            throw PCOError.notSignedIn
        }
    }

    // MARK: API

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        guard let t = tokens else { throw PCOError.notSignedIn }
        if t.expires.timeIntervalSinceNow < 60 { try await refresh() }
        for attempt in 0..<2 {
            var c = URLComponents(string: Self.base + path)!
            c.queryItems = query.map { .init(name: $0.key, value: $0.value) }
            var req = URLRequest(url: c.url!)
            req.setValue("Bearer \(tokens?.access ?? "")", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && attempt == 0 { try await refresh(); continue }
            guard status == 200 else { throw PCOError.failed("Planning Center returned an error (\(status)).") }
            return data
        }
        throw PCOError.notSignedIn
    }

    func serviceTypes() async throws -> [PCOServiceType] {
        struct Doc: Decodable {
            struct Item: Decodable { var id: String; var attributes: Attrs }
            struct Attrs: Decodable { var name: String }
            var data: [Item]
        }
        let doc = try JSONDecoder().decode(Doc.self, from: try await get("/services/v2/service_types", ["per_page": "100", "order": "name"]))
        return doc.data.map { PCOServiceType(id: $0.id, name: $0.attributes.name) }
    }

    /// Start times of the service type's real services (not rehearsals) for today and upcoming plans.
    func serviceTimes(typeID: String) async throws -> [Date] {
        struct Doc: Decodable {
            struct Item: Decodable {
                var type: String
                var attributes: Attrs?
            }
            struct Attrs: Decodable { var starts_at: String?; var time_type: String? }
            var included: [Item]?
        }
        // "past" is on or before today (so today's service is included); "future" is everything upcoming.
        var included: [Doc.Item] = []
        for (filter, order, count) in [("future", "sort_date", "12"), ("past", "-sort_date", "3")] {
            let data = try await get("/services/v2/service_types/\(typeID)/plans", [
                "filter": filter, "order": order, "per_page": count, "include": "plan_times"])
            included += try JSONDecoder().decode(Doc.self, from: data).included ?? []
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return included.compactMap { item -> Date? in
            guard item.type == "PlanTime", item.attributes?.time_type == "service", let s = item.attributes?.starts_at else { return nil }
            return plain.date(from: s) ?? fractional.date(from: s)
        }.sorted()
    }

    /// Names and titles worth telling Whisper about for today's plan (or the next one): who is speaking,
    /// then the series and plan titles. The rest of the roster is left out: every name costs a little delay.
    func planTerms(typeID: String) async throws -> [String] {
        struct Plans: Decodable {
            struct Plan: Decodable { var id: String; var attributes: Attrs }
            struct Attrs: Decodable { var title: String?; var series_title: String?; var sort_date: String? }
            var data: [Plan]
        }
        func plan(_ filter: String, _ order: String) async throws -> Plans.Plan? {
            let data = try await get("/services/v2/service_types/\(typeID)/plans", ["filter": filter, "order": order, "per_page": "1"])
            return try JSONDecoder().decode(Plans.self, from: data).data.first
        }
        // "past" is on or before today, so its newest plan is today's if there is one.
        let latest = try await plan("past", "-sort_date")
        let today = latest.flatMap { $0.attributes.sort_date }.flatMap { ISO8601DateFormatter().date(from: $0) }.map(Calendar.current.isDateInToday) ?? false
        let next = try await plan("future", "sort_date")
        guard let chosen = today ? latest : next else { return [] }

        struct Members: Decodable {
            struct Member: Decodable { var attributes: Attrs; var relationships: Rels? }
            struct Attrs: Decodable { var name: String?; var status: String?; var team_position_name: String? }
            struct Rels: Decodable { var team: Ref? }
            struct Ref: Decodable { var data: Target? }
            struct Target: Decodable { var id: String }
            struct Team: Decodable { var type: String; var id: String; var attributes: TeamAttrs? }
            struct TeamAttrs: Decodable { var name: String? }
            var data: [Member]
            var included: [Team]?
        }
        let members = try JSONDecoder().decode(Members.self, from: try await get(
            "/services/v2/service_types/\(typeID)/plans/\(chosen.id)/team_members", ["include": "team", "per_page": "100"]))
        var teams: [String: String] = [:]
        for t in members.included ?? [] where t.type == "Team" { teams[t.id] = t.attributes?.name ?? "" }
        var speakers: [String] = []
        for m in members.data {
            guard let name = m.attributes.name, m.attributes.status?.lowercased().hasPrefix("d") != true else { continue }  // not declined
            let position = (m.attributes.team_position_name ?? "").lowercased()
            let team = (m.relationships?.team?.data.flatMap { teams[$0.id] } ?? "").lowercased()
            if Self.speakerWords.contains(where: { position.contains($0) || team.contains($0) }) { speakers.append(name) }
        }
        return speakers + [chosen.attributes.series_title, chosen.attributes.title].compactMap { $0 }
    }

    /// A team or position with one of these in its name is someone who talks from the stage.
    private static let speakerWords = ["speak", "teach", "preach", "pastor", "sermon", "message", "emcee"]
}

/// Catches the browser's redirect back to http://127.0.0.1:<port>/callback and returns the OAuth code.
private enum LoopbackServer {
    static func waitForCode(port: UInt16, state: String, timeout: TimeInterval) async throws -> String {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            @Sendable func finish(_ r: Result<String, Error>) {
                guard once.first() else { return }
                listener.cancel()
                cont.resume(with: r)
            }
            listener.stateUpdateHandler = {
                if case .failed(let e) = $0 { finish(.failure(PCOError.failed("Couldn't wait for the sign-in (\(e.localizedDescription))."))) }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                    let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let ok = target.hasPrefix("/callback") && code != nil && items.first { $0.name == "state" }?.value == state
                    let page = ok ? "Signed in. You can close this tab and return to Transcriber." : "Sign-in didn’t complete. Close this tab and try again from Transcriber."
                    let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(page)</h2></body></html>"
                    let http = "HTTP/1.1 \(target.hasPrefix("/callback") ? 200 : 404) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(http.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if target.hasPrefix("/callback") { finish(ok ? .success(code!) : .failure(PCOError.failed("Planning Center sign-in was denied."))) }
                }
            }
            listener.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(PCOError.cancelled)) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}
