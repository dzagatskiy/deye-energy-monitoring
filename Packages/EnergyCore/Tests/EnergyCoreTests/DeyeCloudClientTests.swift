import Foundation
import Testing
@testable import EnergyCore

/// Fake HTTP layer. Each test gets its own session tagged with a header, so parallel tests don't collide.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String, _ body: [String: Any], _ headers: [String: String]) -> (Int, Data, [String: String])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var logs: [String: [(path: String, body: [String: Any], auth: String?)]] = [:]

    static func session(_ handler: @escaping Handler) -> (URLSession, String) {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler; logs[id] = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-ID": id]
        return (URLSession(configuration: config), id)
    }

    static func requests(_ id: String) -> [(path: String, body: [String: Any], auth: String?)] {
        lock.withLock { logs[id] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub-ID") ?? ""
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bodyData.append(buffer, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]) ?? [:]
        let path = request.url!.path.replacingOccurrences(of: "/v1.0/", with: "")
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let handler = Self.lock.withLock { () -> Handler? in
            Self.logs[id, default: []].append((path, body, auth))
            return Self.handlers[id]
        }
        let (status, data, headers) = handler?(path, body, request.allHTTPHeaderFields ?? [:]) ?? (500, Data(), [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("DeyeCloudClient")
struct DeyeCloudClientTests {
    let credentials = DeyeCloudCredentials(appId: "app", appSecret: "secret", email: "user@example.com", password: "pw")

    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/DeyeCloud")!
        let wrapper = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return try! JSONSerialization.data(withJSONObject: wrapper["response"]!)
    }

    static func tokenJSON(_ token: String, expiresIn: Int = 5_183_999) -> Data {
        Data(#"{"code":"1000000","msg":"success","success":true,"accessToken":"\#(token)","expiresIn":"\#(expiresIn)"}"#.utf8)
    }

    static let invalidToken = Data(#"{"code":"2101019","msg":"auth invalid token","success":false}"#.utf8)

    @Test("Password is sent as SHA-256 hex, never in plaintext")
    func passwordHash() {
        // sha256("pw")
        #expect(credentials.passwordSHA256 == "30c952fab122c3f9759f02a6d95c3758b246b4fee239957b2d4fee46e26170c4")
    }

    @Test("Logs in once, then reuses the cached token with a bearer header")
    func tokenCaching() async throws {
        let (session, id) = StubURLProtocol.session { path, _, _ in
            path == "account/token" ? (200, Self.tokenJSON("T1"), [:]) : (200, Self.fixture("pinned_latest_grid_off"), [:])
        }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: InMemoryDeyeTokenStore(), session: session, limiter: .unlimited)
        _ = try await client.latest([InverterID("sn")])
        _ = try await client.latest([InverterID("sn")])
        let log = StubURLProtocol.requests(id)
        #expect(log.map(\.path) == ["account/token", "device/latest", "device/latest"])
        #expect(log[0].body["password"] as? String == credentials.passwordSHA256)
        #expect(log[1].auth == "bearer T1")
        #expect(log[1].body["deviceList"] as? [String] == ["sn"])
    }

    @Test("Expired or revoked token: logs in again once and retries")
    func reLogin() async throws {
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "OLD", expiresAt: .distantFuture))
        let (session, id) = StubURLProtocol.session { path, _, headers in
            if path == "account/token" { return (200, Self.tokenJSON("NEW"), [:]) }
            return headers["Authorization"] == "bearer NEW"
                ? (200, Self.fixture("pinned_latest_grid_off"), [:])
                : (200, Self.invalidToken, [:])
        }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: session, limiter: .unlimited)
        let samples = try await client.latest([InverterID("sn")])
        #expect(samples.first?.gridState == .off)
        #expect(StubURLProtocol.requests(id).map(\.path) == ["device/latest", "account/token", "device/latest"])
        #expect(await store.load()?.accessToken == "NEW")
    }

    @Test("Token close to expiry is renewed proactively")
    func renewal() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "OLD", expiresAt: now.addingTimeInterval(3600)))
        let (session, id) = StubURLProtocol.session { path, _, _ in
            path == "account/token" ? (200, Self.tokenJSON("NEW", expiresIn: 7200), [:]) : (200, Self.fixture("pinned_latest_grid_on"), [:])
        }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: session, limiter: .unlimited, now: { now })
        _ = try await client.latest([InverterID("sn")])
        #expect(StubURLProtocol.requests(id).first?.path == "account/token")
        #expect(await store.load() == DeyeToken(accessToken: "NEW", expiresAt: now.addingTimeInterval(7200)))
    }

    @Test("Wrong credentials surface as unauthorized")
    func badCredentials() async {
        let (session, _) = StubURLProtocol.session { _, _, _ in
            (200, Data(#"{"code":"2101003","msg":"user or password error","success":false}"#.utf8), [:])
        }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: InMemoryDeyeTokenStore(), session: session, limiter: .unlimited)
        await #expect(throws: DataSourceError.unauthorized) { try await client.latest([InverterID("sn")]) }
    }

    @Test("HTTP 429 maps to rateLimited with Retry-After; 5xx to network error")
    func httpErrors() async {
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: .distantFuture))
        let (s429, _) = StubURLProtocol.session { _, _, _ in (429, Data(), ["Retry-After": "30"]) }
        let limited = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: s429, limiter: .unlimited)
        await #expect(throws: DataSourceError.rateLimited(retryAfter: 30)) { try await limited.latest([InverterID("sn")]) }

        let (s502, _) = StubURLProtocol.session { _, _, _ in (502, Data(), [:]) }
        let broken = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: s502, limiter: .unlimited)
        await #expect(throws: DataSourceError.network("HTTP 502")) { try await broken.latest([InverterID("sn")]) }
    }

    @Test("History is fetched in batches of at most 5 measure points and merged")
    func historyBatches() async throws {
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: .distantFuture))
        let (session, id) = StubURLProtocol.session { _, body, _ in
            let points = body["measurePoints"] as? [String] ?? []
            if points.count > 5 { return (200, Self.fixture("pinned_error_list_too_long"), [:]) }
            return points.contains("SOC")
                ? (200, Self.fixture("pinned_history_grid_on_day"), [:])
                : (200, Data(#"{"code":"1000000","success":true,"dataList":[]}"#.utf8), [:])
        }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: session, limiter: .unlimited)
        let samples = try await client.history(InverterID("sn"), day: "2026-11-23")
        #expect(samples.count == 106)
        let log = StubURLProtocol.requests(id)
        #expect(log.count == DeyeCloudMapper.Key.historyBatches.count)
        #expect(log.allSatisfy { ($0.body["measurePoints"] as? [String])?.count ?? 99 <= 5 })
        #expect(log.allSatisfy { $0.body["startAt"] as? String == "2026-11-23" && $0.body["granularity"] as? Int == 1 })
    }

    @Test("Inverter discovery via /station/listWithDevice")
    func discovery() async throws {
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: .distantFuture))
        let (session, id) = StubURLProtocol.session { _, _, _ in (200, Self.fixture("pinned_station_list_with_device"), [:]) }
        let client = DeyeCloudClient(region: .eu, credentials: credentials, tokenStore: store, session: session, limiter: .unlimited)
        #expect(try await client.inverters().count == 2)
        #expect(StubURLProtocol.requests(id).first?.body["deviceType"] as? String == "INVERTER")
    }

    @Test("Source splits a history range into calendar days of the profile's time zone")
    func sourceDays() {
        let kyiv = TimeZone(identifier: "Europe/Kyiv")!
        // 2026-11-22 23:30 Kyiv → 2026-11-23 00:30 Kyiv
        let start = Date(timeIntervalSince1970: 1_795_383_000)
        let days = DeyeCloudSource.days(in: DateInterval(start: start, duration: 3600), timeZone: kyiv)
        #expect(days == ["2026-11-22", "2026-11-23"])
    }
}
