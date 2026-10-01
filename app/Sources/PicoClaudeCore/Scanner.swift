import Foundation

/// Incrementally reads Claude Code transcripts (`~/.claude/projects/**/*.jsonl`)
/// and keeps the last eight days of assistant-message usage.
/// Not thread-safe: call `scan` from one queue.
public final class TranscriptScanner: @unchecked Sendable {
    struct Entry {
        var ts: Double
        var model: String
        var tok: Int
        var out: Int
    }

    static let keepSeconds: Double = 8 * 86400

    let root: URL
    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:]
    private static let needle = Data("\"usage\"".utf8)
    private static let newline = UInt8(ascii: "\n")

    public init(projectsDir: URL) {
        root = projectsDir
    }

    static func parseTimestamp(_ s: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.timeIntervalSince1970
    }

    /// (dedup key, entry) for an assistant line that carries usage, else nil.
    static func parse(line: Data) -> (String, Entry)? {
        guard line.range(of: needle) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant",
              let msg = d["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let ts = (d["timestamp"] as? String).flatMap(parseTimestamp) else { return nil }
        func n(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let out = n("output_tokens")
        let tok = n("input_tokens") + out + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
        let key = "\(msg["id"] as? String ?? ""):\(d["requestId"] as? String ?? "")"
        return (key, Entry(ts: ts, model: model, tok: tok, out: out))
    }

    /// Read whatever was appended since the last scan and return hourly buckets.
    public func scan(now: Date = Date()) -> [HourBucket] {
        let cutoff = now.timeIntervalSince1970 - Self.keepSeconds
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate,
                      let size = values.fileSize else { continue }
                let path = url.path
                if modified.timeIntervalSince1970 < cutoff {
                    offsets[path] = nil
                    continue
                }
                var offset = offsets[path] ?? 0
                if UInt64(size) < offset { offset = 0 }       // truncated or rewritten
                if UInt64(size) == offset { continue }
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: offset)) != nil,
                      let data = try? handle.readToEnd() else { continue }
                // only consume whole lines; a partial last line is re-read next time
                guard let end = data.lastIndex(of: Self.newline) else { continue }
                offsets[path] = offset + UInt64(end - data.startIndex + 1)
                for line in data[data.startIndex...end].split(separator: Self.newline) {
                    // a message is logged once per content block and the last
                    // line has the final output count, so later lines win
                    if let (key, entry) = Self.parse(line: Data(line)), entry.ts >= cutoff {
                        entries[key] = entry
                    }
                }
            }
        }
        entries = entries.filter { $0.value.ts >= cutoff }

        struct Key: Hashable { var hour: Int; var model: String }
        var buckets: [Key: HourBucket] = [:]
        let latest = now.timeIntervalSince1970 + 60
        for e in entries.values where e.ts <= latest {
            let key = Key(hour: Int(e.ts / 3600), model: e.model)
            var b = buckets[key] ?? HourBucket(hour: key.hour, model: key.model, tok: 0, out: 0, msgs: 0)
            b.tok += e.tok
            b.out += e.out
            b.msgs += 1
            buckets[key] = b
        }
        return buckets.values.sorted { ($0.hour, $0.model) < ($1.hour, $1.model) }
    }
}

/// Plan limits from the statusline JSON that statusline-tee.sh saves for each
/// session: the best reading across sessions (see `Aggregator.best`). The
/// capture time is the file's modification time; captures older than eight
/// days are deleted.
public func readLimits(statuslineDir: URL, now: Int) -> (h5: LimitWindow?, d7: LimitWindow?) {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: statuslineDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    var h5: [LimitWindow] = [], d7: [LimitWindow] = []
    for file in files where file.pathExtension == "json" {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { continue }
        let captured = Int(modified.timeIntervalSince1970)
        if captured < now - 8 * 86400 {
            try? FileManager.default.removeItem(at: file)
            continue
        }
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { continue }
        func window(_ name: String) -> LimitWindow? {
            guard let w = limits[name] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(pct: (pct * 10).rounded() / 10,
                               reset: (w["resets_at"] as? NSNumber)?.intValue ?? 0,
                               ts: captured)
        }
        if let w = window("five_hour") { h5.append(w) }
        if let w = window("seven_day") { d7.append(w) }
    }
    return (Aggregator.best(h5, now: now), Aggregator.best(d7, now: now))
}
