import Foundation

/// Read recent events newest-first across the daily `YYYY-MM-DD.jsonl` files,
/// filtered by an inclusive ISO-8601 `since` and by type (PT-P6-R7). The events
/// log is otherwise append-only and write-owned by `EventWriter`.
// PT-P6-R7
public struct EventLogReader: Sendable {

    public let directory: URL

    public init(directory: URL = AppPaths.standard.eventsDirectory) {
        self.directory = directory
    }

    public struct Entry: Sendable, Equatable {
        public let ts: String
        public let type: String
        public let line: String      // the raw JSON line
    }

    public func recent(since: String? = nil, types: Set<String> = [], limit: Int = 100) throws -> [Entry] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest day first

        let sinceDay = since.flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil }
        var out: [Entry] = []
        for file in files {
            if let sinceDay, file.deletingPathExtension().lastPathComponent < sinceDay { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                guard let entry = Self.parse(String(raw)) else { continue }
                if let since, entry.ts < since { continue }
                if !types.isEmpty, !types.contains(entry.type) { continue }
                out.append(entry)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    static func parse(_ line: String) -> Entry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? String, let type = obj["type"] as? String else { return nil }
        return Entry(ts: ts, type: type, line: line)
    }
}
