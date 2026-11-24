import Foundation
import Testing
@testable import EnergyCore

extension RequestRateLimiter {
    /// For tests that are not about rate limiting: parallel tests must not throttle each other.
    static var unlimited: RequestRateLimiter { RequestRateLimiter(limit: 100_000) }
}

/// Manual clock: `sleep` advances time instantly and records how long callers waited.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private(set) var slept: [TimeInterval] = []

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    func sleep(_ seconds: TimeInterval) { lock.withLock { slept.append(seconds); current += seconds } }

    func limiter(limit: Int, maxWait: TimeInterval = 120) -> RequestRateLimiter {
        RequestRateLimiter(limit: limit, window: 60, maxWait: maxWait, now: { self.now }, sleep: { self.sleep($0) })
    }
}

@Suite("RequestRateLimiter")
struct RateLimiterTests {
    @Test("Default budget stays below Deye's 60 requests per minute")
    func defaults() async {
        let limiter = RequestRateLimiter()
        #expect(limiter.limit <= 60)
        #expect(limiter.window == 60)
    }

    @Test("Requests within the limit go through without waiting")
    func underLimit() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 5)
        for _ in 0..<5 { try await limiter.acquire() }
        #expect(clock.slept.isEmpty)
        #expect(await limiter.recentCount == 5)
    }

    @Test("Request over the limit waits until the oldest one leaves the 60 s window")
    func waitsForWindow() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 3)
        try await limiter.acquire()
        clock.advance(10)
        try await limiter.acquire()
        try await limiter.acquire()
        try await limiter.acquire() // 4th: oldest was 10 s ago → wait 50 s
        #expect(clock.slept == [50])
    }

    @Test("Never more than `limit` requests in any 60 s window")
    func slidingWindowInvariant() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 10)
        var times: [Date] = []
        for _ in 0..<35 {
            try await limiter.acquire()
            times.append(clock.now)
            clock.advance(1)
        }
        for t in times {
            #expect(times.filter { $0 >= t && $0 < t.addingTimeInterval(60) }.count <= 10)
        }
    }

    @Test("Too long a wait fails fast with rateLimited (widget must not hang)")
    func failsFast() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 1, maxWait: 5)
        try await limiter.acquire()
        await #expect(throws: DataSourceError.rateLimited(retryAfter: 60)) { try await limiter.acquire() }
        #expect(clock.slept.isEmpty)
    }

    @Test("HTTP 429 pauses every request for Retry-After")
    func pauseAfter429() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 50)
        await limiter.pause(for: 30)
        try await limiter.acquire()
        #expect(clock.slept == [30])
    }

    @Test("Client sends through the limiter and pauses it on 429")
    func clientIntegration() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(limit: 2, maxWait: 5)
        let store = InMemoryDeyeTokenStore(DeyeToken(accessToken: "T", expiresAt: .distantFuture))
        let creds = DeyeCloudCredentials(appId: "a", appSecret: "s", email: "e", password: "p")

        let (ok, _) = StubURLProtocol.session { _, _, _ in (200, DeyeCloudClientTests.fixture("pinned_latest_grid_on"), [:]) }
        let client = DeyeCloudClient(region: .eu, credentials: creds, tokenStore: store, session: ok, limiter: limiter, now: { clock.now })
        _ = try await client.latest([InverterID("sn")])
        _ = try await client.latest([InverterID("sn")])
        // Third request within the same minute would need a 60 s wait > maxWait.
        await #expect(throws: DataSourceError.rateLimited(retryAfter: 60)) { try await client.latest([InverterID("sn")]) }

        let fresh = clock.limiter(limit: 50, maxWait: 5)
        let (limited, id) = StubURLProtocol.session { _, _, _ in (429, Data(), ["Retry-After": "20"]) }
        let throttled = DeyeCloudClient(region: .eu, credentials: creds, tokenStore: store, session: limited, limiter: fresh, now: { clock.now })
        await #expect(throws: DataSourceError.rateLimited(retryAfter: 20)) { try await throttled.latest([InverterID("sn")]) }
        // While paused (20 s > maxWait 5 s) nothing is sent at all.
        await #expect(throws: DataSourceError.rateLimited(retryAfter: 20)) { try await throttled.latest([InverterID("sn")]) }
        #expect(StubURLProtocol.requests(id).count == 1)
    }
}

@Suite("Polling interval")
struct PollingIntervalTests {
    @Test("Default is 2 min; stored values are clamped to 1…10 min")
    func clamp() {
        #expect(AccountSettings().refreshInterval == 120)
        #expect(AccountSettings.refreshIntervalChoices.allSatisfy { $0 >= 60 && $0 <= 600 })
        var s = AccountSettings()
        s.refreshInterval = 30
        #expect(s.effectiveRefreshInterval == 60)
        s.refreshInterval = 3600
        #expect(s.effectiveRefreshInterval == 600)
    }
}
