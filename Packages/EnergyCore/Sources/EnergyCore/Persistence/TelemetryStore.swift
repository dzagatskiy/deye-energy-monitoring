import Foundation

/// File-based telemetry storage shared by the app and the widget (App Group container).
///
/// Layout: `<root>/samples/<inverterId>/<yyyy-MM-dd UTC>.json`, one JSON array of samples per UTC day.
/// Writes merge with existing content, normalize (sort + dedup, local wins) and replace the file atomically,
/// so a crash or a concurrent reader never sees a half-written file.
/// See docs/adr/0002-file-storage.md for why this is not SwiftData.
public actor TelemetryStore {
    public let root: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    // MARK: Samples

    /// Adds samples (any order, duplicates allowed). Samples without `inverterId` are ignored.
    public func append(_ samples: [TelemetrySample]) throws {
        for (id, perInverter) in SampleSeries.grouped(samples) {
            let byDay = Dictionary(grouping: perInverter) { Self.dayKey($0.timestamp) }
            for (day, newSamples) in byDay {
                let url = fileURL(id, day: day)
                let merged = SampleSeries.normalize(readFile(url) + newSamples)
                try write(merged, to: url)
            }
        }
    }

    public func samples(_ id: InverterID, in range: DateInterval) -> [TelemetrySample] {
        var result: [TelemetrySample] = []
        var cursor = range.start
        while true {
            let day = Self.dayKey(cursor)
            result += readFile(fileURL(id, day: day)).filter { range.contains($0.timestamp) }
            guard let next = Self.utc.date(byAdding: .day, value: 1, to: Self.utc.startOfDay(for: cursor)), next <= range.end else { break }
            cursor = next
        }
        return SampleSeries.normalize(result)
    }

    /// Latest stored sample, looking back up to `lookbackDays` days.
    public func latest(_ id: InverterID, now: Date, lookbackDays: Int = 7) -> TelemetrySample? {
        for offset in 0...lookbackDays {
            let date = now.addingTimeInterval(-Double(offset) * 86_400)
            if let last = readFile(fileURL(id, day: Self.dayKey(date))).last(where: { $0.timestamp <= now }) {
                return last
            }
        }
        return nil
    }

    /// Deletes day files older than `days` (raw samples retention; outages are recomputed from what is kept).
    public func prune(olderThan days: Int, now: Date) throws {
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(days) * 86_400))
        let base = root.appendingPathComponent("samples")
        guard let inverters = try? fileManager.contentsOfDirectory(atPath: base.path) else { return }
        for inverter in inverters {
            let dir = base.appendingPathComponent(inverter)
            for file in (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? [] where file < "\(cutoff).json" {
                try fileManager.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    // MARK: Generic JSON documents (snapshots, sync state, settings)

    public func save<T: Encodable>(_ value: T, as name: String) throws {
        try writeData(try encoder.encode(value), to: root.appendingPathComponent(name))
    }

    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: Internals

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func dayKey(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func fileURL(_ id: InverterID, day: String) -> URL {
        let safe = id.rawValue.replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent("samples").appendingPathComponent(safe).appendingPathComponent("\(day).json")
    }

    private func readFile(_ url: URL) -> [TelemetrySample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([TelemetrySample].self, from: data)) ?? []
    }

    private func write(_ samples: [TelemetrySample], to url: URL) throws {
        try writeData(try encoder.encode(samples), to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
