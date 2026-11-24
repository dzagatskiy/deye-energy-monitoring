import Foundation

/// Abstraction over any inverter data provider (Deye Cloud, Solarman V5 on LAN, future vendors).
/// Implementations return normalized `TelemetrySample`s; business logic never sees vendor DTOs.
public protocol InverterDataSource: Sendable {
    var kind: SourceKind { get }
    func fetchLatest() async throws -> TelemetrySample
    /// Historical samples in the given range. Sources that cannot do this throw `.historyNotSupported`.
    func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample]
}

public enum DataSourceError: Error, Sendable, Equatable {
    case unavailable
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case emptyResponse
    case invalidResponse(String)
    case network(String)
    case historyNotSupported
    /// The token expired and the password was not remembered: the user has to log in again.
    case loginRequired
}

public struct SourceFailure: Sendable, Equatable {
    public var source: SourceKind
    public var error: DataSourceError
}

public enum SourceRouterError: Error, Sendable, Equatable {
    case noSourcesConfigured
    case allSourcesFailed([SourceFailure])
}

public struct RoutedSample: Sendable, Equatable {
    public var sample: TelemetrySample
    /// Sources that failed before this one succeeded (e.g. local unreachable → cloud).
    public var failures: [SourceFailure]
}

/// Tries sources in priority order (local first, then cloud) and returns the first success.
public struct SourceRouter: Sendable {
    public var sources: [any InverterDataSource]

    public init(sources: [any InverterDataSource]) {
        self.sources = sources
    }

    public func fetchLatest() async throws -> RoutedSample {
        guard !sources.isEmpty else { throw SourceRouterError.noSourcesConfigured }
        var failures: [SourceFailure] = []
        for source in sources {
            do {
                let sample = try await source.fetchLatest()
                return RoutedSample(sample: sample, failures: failures)
            } catch let error as DataSourceError {
                failures.append(SourceFailure(source: source.kind, error: error))
            } catch {
                failures.append(SourceFailure(source: source.kind, error: .network(String(describing: error))))
            }
        }
        throw SourceRouterError.allSourcesFailed(failures)
    }

    /// History comes from the first source that supports it (currently only the cloud).
    public func fetchHistory(_ range: DateInterval) async throws -> [TelemetrySample] {
        guard !sources.isEmpty else { throw SourceRouterError.noSourcesConfigured }
        var failures: [SourceFailure] = []
        for source in sources {
            do {
                return try await source.fetchHistory(range)
            } catch let error as DataSourceError {
                failures.append(SourceFailure(source: source.kind, error: error))
            } catch {
                failures.append(SourceFailure(source: source.kind, error: .network(String(describing: error))))
            }
        }
        throw SourceRouterError.allSourcesFailed(failures)
    }
}
