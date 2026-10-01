import Foundation

/// One plan-limit window (5-hour or 7-day) as read from a statusline capture.
public struct LimitWindow: Codable, Equatable {
    public var pct: Double
    /// Unix time the window resets; 0 when unknown or already passed.
    public var reset: Int
    /// Unix time the reading was captured.
    public var ts: Int

    public init(pct: Double, reset: Int, ts: Int) {
        self.pct = pct
        self.reset = reset
        self.ts = ts
    }
}

/// Token usage for one model in one UTC hour (`hour` = unix time / 3600).
public struct HourBucket: Equatable {
    public var hour: Int
    public var model: String
    public var tok: Int
    public var out: Int
    public var msgs: Int

    public init(hour: Int, model: String, tok: Int, out: Int, msgs: Int) {
        self.hour = hour
        self.model = model
        self.tok = tok
        self.out = out
        self.msgs = msgs
    }
}

/// What one host knows: its limit readings and its own token usage.
/// Remote hosts send this as JSON (see agent/usage.py `build_report`).
public struct HostReport: Equatable {
    public var host: String
    public var ts: Int
    public var h5: LimitWindow?
    public var d7: LimitWindow?
    public var hours: [HourBucket]

    public init(host: String, ts: Int, h5: LimitWindow?, d7: LimitWindow?, hours: [HourBucket]) {
        self.host = host
        self.ts = ts
        self.h5 = h5
        self.d7 = d7
        self.hours = hours
    }

    /// Decode an agent report. Returns nil for anything malformed.
    public init?(json: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let host = obj["host"] as? String,
              let ts = (obj["ts"] as? NSNumber)?.intValue else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any],
                  let pct = (w["pct"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(pct: pct,
                               reset: (w["reset"] as? NSNumber)?.intValue ?? 0,
                               ts: (w["ts"] as? NSNumber)?.intValue ?? ts)
        }
        var hours: [HourBucket] = []
        for row in obj["hours"] as? [[Any]] ?? [] {
            guard row.count >= 5,
                  let hour = (row[0] as? NSNumber)?.intValue,
                  let model = row[1] as? String,
                  let tok = (row[2] as? NSNumber)?.intValue,
                  let out = (row[3] as? NSNumber)?.intValue,
                  let msgs = (row[4] as? NSNumber)?.intValue else { continue }
            hours.append(HourBucket(hour: hour, model: model, tok: tok, out: out, msgs: msgs))
        }
        self.init(host: host, ts: ts, h5: window("h5"), d7: window("d7"), hours: hours)
    }
}

/// The message the Pico display consumes (topic `claude/usage`).
public struct UsagePayload: Codable, Equatable {
    public struct Today: Codable, Equatable {
        public var tok: Int
        public var out: Int
        public var msgs: Int

        public init(tok: Int, out: Int, msgs: Int) {
            self.tok = tok
            self.out = out
            self.msgs = msgs
        }
    }

    public var v = 1
    public var ts: Int
    /// Seconds east of UTC, so the display can show local time.
    public var tz: Int
    public var h5: LimitWindow?
    public var d7: LimitWindow?
    public var today: Today
    /// Tokens per local day, oldest first, today last.
    public var week: [Int]
    public var model: String

    public init(ts: Int, tz: Int, h5: LimitWindow?, d7: LimitWindow?, today: Today, week: [Int], model: String) {
        self.ts = ts
        self.tz = tz
        self.h5 = h5
        self.d7 = d7
        self.today = today
        self.week = week
        self.model = model
    }

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// claude-fable-5-1 -> "Fable 5.1", claude-haiku-4-5-20251001 -> "Haiku 4.5".
public func prettyModel(_ id: String) -> String {
    let parts = id.split(separator: "-").map(String.init).filter { $0 != "claude" }
    let isNumber: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    let words = parts.filter { !isNumber($0) }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    let numbers = parts.filter { isNumber($0) && $0.count != 8 }   // drop date suffix
    return (words + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
}
