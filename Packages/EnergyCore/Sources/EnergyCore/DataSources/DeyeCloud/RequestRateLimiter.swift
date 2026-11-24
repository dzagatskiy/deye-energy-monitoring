import Foundation

/// Sliding-window limiter for Deye Cloud requests.
///
/// Deye recommends at most 60 requests per minute per application (HTTP 429 above that).
/// The limiter keeps headroom below that (`limit` 50 by default) because the widget extension runs in a
/// separate process with its own limiter. After a 429 it pauses all requests for `Retry-After` (or 60 s).
///
/// A caller that would have to wait longer than `maxWait` gets `.rateLimited` immediately instead of blocking
/// (important for the widget, which has only a few seconds per update).
public actor RequestRateLimiter {
    public static let shared = RequestRateLimiter()

    public nonisolated let limit: Int
    public nonisolated let window: TimeInterval
    public nonisolated let maxWait: TimeInterval
    private var stamps: [Date] = []
    private var pausedUntil: Date?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        limit: Int = 50,
        window: TimeInterval = 60,
        maxWait: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.limit = max(1, limit)
        self.window = window
        self.maxWait = maxWait
        self.now = now
        self.sleep = sleep
    }

    /// Waits for a free slot (up to `maxWait`) and takes it.
    public func acquire() async throws {
        while true {
            let current = now()
            stamps.removeAll { current.timeIntervalSince($0) >= window }

            var wait: TimeInterval = 0
            if let pausedUntil, pausedUntil > current {
                wait = pausedUntil.timeIntervalSince(current)
            } else if stamps.count >= limit, let oldest = stamps.first {
                wait = oldest.addingTimeInterval(window).timeIntervalSince(current)
            }

            if wait <= 0 {
                stamps.append(current)
                return
            }
            if wait > maxWait { throw DataSourceError.rateLimited(retryAfter: wait) }
            try await sleep(wait)
        }
    }

    /// Called on HTTP 429: stop sending until the server's `Retry-After` (default one full window).
    public func pause(for seconds: TimeInterval?) {
        let until = now().addingTimeInterval(seconds ?? window)
        pausedUntil = max(pausedUntil ?? .distantPast, until)
    }

    /// Requests made in the current window (for diagnostics and tests).
    public var recentCount: Int {
        let current = now()
        return stamps.filter { current.timeIntervalSince($0) < window }.count
    }
}
