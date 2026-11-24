import CryptoKit
import Foundation

public enum DeyeRegion: String, Sendable, Codable, CaseIterable {
    case eu, us, india

    public var baseURL: URL {
        switch self {
        case .eu: URL(string: "https://eu1-developer.deyecloud.com/v1.0")!
        case .us: URL(string: "https://us1-developer.deyecloud.com/v1.0")!
        case .india: URL(string: "https://india-developer.deyecloud.com/v1.0")!
        }
    }
}

/// Developer application keys from developer.deyecloud.com → Application.
/// Not personal secrets of the end user, but still kept in the Keychain (they grant API quota).
public struct DeyeAppCredentials: Sendable, Codable, Equatable {
    public var appId: String
    public var appSecret: String

    public init(appId: String, appSecret: String) {
        self.appId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap local sanity check before the first network call (exact formats are not documented).
    public var isPlausible: Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        func ok(_ s: String, min: Int) -> Bool {
            s.count >= min && s.count <= 128 && s.unicodeScalars.allSatisfy(allowed.contains)
        }
        return ok(appId, min: 6) && ok(appSecret, min: 16)
    }
}

/// The end user's Deye Cloud account. `passwordSHA256 == nil` means the user chose not to remember
/// the password: the app then lives on the issued token (~60 days) and asks to log in again after that.
public struct DeyeAccount: Sendable, Codable, Equatable {
    public var email: String
    public var passwordSHA256: String?

    public init(email: String, passwordSHA256: String?) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.passwordSHA256 = passwordSHA256
    }

    public var remembersPassword: Bool { passwordSHA256 != nil }

    public static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything the token endpoint needs. The password is only ever handled as its SHA-256 hex digest,
/// which is what the API expects, so the plaintext is never stored.
public struct DeyeCloudCredentials: Sendable, Codable, Equatable {
    public var appId: String
    public var appSecret: String
    public var email: String
    public var passwordSHA256: String?

    public init(appId: String, appSecret: String, email: String, passwordSHA256: String?) {
        self.appId = appId
        self.appSecret = appSecret
        self.email = email
        self.passwordSHA256 = passwordSHA256
    }

    public init(appId: String, appSecret: String, email: String, password: String) {
        self.init(appId: appId, appSecret: appSecret, email: email, passwordSHA256: DeyeAccount.hash(password))
    }

    public init(app: DeyeAppCredentials, account: DeyeAccount) {
        self.init(appId: app.appId, appSecret: app.appSecret, email: account.email, passwordSHA256: account.passwordSHA256)
    }

    public var app: DeyeAppCredentials { DeyeAppCredentials(appId: appId, appSecret: appSecret) }
}

public struct DeyeToken: Sendable, Codable, Equatable {
    public var accessToken: String
    public var expiresAt: Date

    public init(accessToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

/// Persists the access token (Keychain in the app, in-memory in tests) so the widget and the app share it.
public protocol DeyeTokenStore: Sendable {
    func load() async -> DeyeToken?
    func save(_ token: DeyeToken?) async
}

public actor InMemoryDeyeTokenStore: DeyeTokenStore {
    private var token: DeyeToken?
    public init(_ token: DeyeToken? = nil) { self.token = token }
    public func load() -> DeyeToken? { token }
    public func save(_ token: DeyeToken?) { self.token = token }
}

/// Thin client for the read-only Deye Cloud endpoints the app needs.
///
/// - Token is cached and renewed a day before expiry; on "auth invalid token" it logs in again once.
/// - Every request goes through `RequestRateLimiter` (Deye: ≤ 60 requests/min); HTTP 429 pauses it
///   and maps to `.rateLimited` with `Retry-After` when present.
/// - History is requested in batches of ≤ 5 measure points (the API rejects longer lists).
public actor DeyeCloudClient {
    public let region: DeyeRegion
    private let credentials: DeyeCloudCredentials
    private let tokenStore: any DeyeTokenStore
    private let session: URLSession
    private let limiter: RequestRateLimiter
    private let now: @Sendable () -> Date
    private let tokenRenewalMargin: TimeInterval = 24 * 3600

    public init(
        region: DeyeRegion,
        credentials: DeyeCloudCredentials,
        tokenStore: any DeyeTokenStore,
        session: URLSession = .shared,
        limiter: RequestRateLimiter = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.region = region
        self.credentials = credentials
        self.tokenStore = tokenStore
        self.session = session
        self.limiter = limiter
        self.now = now
    }

    // MARK: - Public API

    public func inverters() async throws -> [InverterDescriptor] {
        let data = try await authorizedPost("station/listWithDevice", ["page": 1, "size": 50, "deviceType": "INVERTER"])
        return try DeyeCloudMapper.inverters(fromStationList: data)
    }

    /// Latest samples for up to 10 inverters per request (API limit), batched transparently.
    public func latest(_ ids: [InverterID], detector: GridStateDetector = GridStateDetector()) async throws -> [TelemetrySample] {
        var result: [TelemetrySample] = []
        for chunk in ids.chunked(10) {
            let data = try await authorizedPost("device/latest", ["deviceList": chunk.map(\.rawValue)])
            result += try DeyeCloudMapper.samples(fromLatest: data, detector: detector)
        }
        return result
    }

    /// Frames for one calendar day ("yyyy-MM-dd"), all measure-point batches merged.
    public func history(_ id: InverterID, day: String, detector: GridStateDetector = GridStateDetector()) async throws -> [TelemetrySample] {
        var responses: [Data] = []
        for batch in DeyeCloudMapper.Key.historyBatches {
            responses.append(try await authorizedPost("device/history", [
                "deviceSn": id.rawValue, "granularity": 1, "startAt": day, "endAt": day, "measurePoints": batch,
            ]))
        }
        return try DeyeCloudMapper.samples(fromHistory: responses, detector: detector)
    }

    // MARK: - Token

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        let stored = await tokenStore.load()
        if !forceRefresh, let token = stored, token.expiresAt.timeIntervalSince(now()) > tokenRenewalMargin {
            return token.accessToken
        }
        guard let passwordSHA256 = credentials.passwordSHA256 else {
            // Password not remembered: keep using the token until it actually expires, then ask the user.
            if !forceRefresh, let token = stored, token.expiresAt > now() { return token.accessToken }
            throw DataSourceError.loginRequired
        }
        var components = URLComponents(url: region.baseURL.appendingPathComponent("account/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "appId", value: credentials.appId)]
        let data = try await send(components.url!, body: [
            "appSecret": credentials.appSecret, "email": credentials.email, "password": passwordSHA256,
        ], token: nil)
        let response: DeyeTokenResponse
        do {
            response = try JSONDecoder().decode(DeyeTokenResponse.self, from: data)
        } catch {
            throw DataSourceError.invalidResponse("Undecodable /account/token")
        }
        guard response.success, let access = response.accessToken, !access.isEmpty else {
            // Wrong AppId/secret/password: the user must fix credentials, retrying will not help.
            await tokenStore.save(nil)
            throw DataSourceError.unauthorized
        }
        let lifetime = response.expiresIn.flatMap(TimeInterval.init) ?? 24 * 3600
        await tokenStore.save(DeyeToken(accessToken: access, expiresAt: now().addingTimeInterval(lifetime)))
        return access
    }

    // MARK: - HTTP

    private func authorizedPost(_ path: String, _ body: [String: any Sendable]) async throws -> Data {
        let url = region.baseURL.appendingPathComponent(path)
        let data = try await send(url, body: body, token: try await accessToken())
        guard Self.envelopeCode(data) == DeyeResultCode.invalidToken else { return data }
        // Token revoked or expired early: log in again once.
        return try await send(url, body: body, token: try await accessToken(forceRefresh: true))
    }

    private func send(_ url: URL, body: [String: any Sendable], token: String?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await limiter.acquire()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw DataSourceError.network(error.code == .timedOut ? "timeout" : error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw DataSourceError.network("no HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw DataSourceError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            await limiter.pause(for: retryAfter)
            throw DataSourceError.rateLimited(retryAfter: retryAfter)
        default: throw DataSourceError.network("HTTP \(http.statusCode)")
        }
    }

    static func envelopeCode(_ data: Data) -> String? {
        try? JSONDecoder().decode(DeyeEnvelope.self, from: data).code
    }
}

/// `InverterDataSource` for one inverter backed by Deye Cloud.
public struct DeyeCloudSource: InverterDataSource {
    public let kind = SourceKind.cloud
    public let client: DeyeCloudClient
    public let inverterId: InverterID
    public let profile: InverterProfile

    public init(client: DeyeCloudClient, profile: InverterProfile) {
        self.client = client
        self.inverterId = profile.id
        self.profile = profile
    }

    public func fetchLatest() async throws -> TelemetrySample {
        guard let sample = try await client.latest([inverterId], detector: profile.detector)
            .first(where: { $0.inverterId == inverterId }) else { throw DataSourceError.emptyResponse }
        return sample
    }

    /// Fetches every calendar day touched by `range` (days in the profile's time zone) and trims to the range.
    public func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample] {
        var all: [TelemetrySample] = []
        for day in Self.days(in: range, timeZone: profile.timeZone) {
            all += try await client.history(inverterId, day: day, detector: profile.detector)
        }
        return SampleSeries.normalize(all.filter { range.contains($0.timestamp) })
    }

    static func days(in range: DateInterval, timeZone: TimeZone) -> [String] {
        let calendar = OutageStatistics.calendar(in: timeZone)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var result: [String] = []
        var cursor = calendar.startOfDay(for: range.start)
        while cursor <= range.end {
            result.append(formatter.string(from: cursor))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return result
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
