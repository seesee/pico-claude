import Foundation

public enum Aggregator {
    /// Newest reading of a window across hosts. Limits are account-wide, so
    /// whichever host heard from Anthropic most recently is the truth.
    /// A window whose reset time has passed reads as 0%.
    public static func newest(_ windows: [LimitWindow?], now: Int) -> LimitWindow? {
        guard var best = windows.compactMap({ $0 }).max(by: { $0.ts < $1.ts }) else { return nil }
        if best.reset != 0 && best.reset <= now {
            best.pct = 0
            best.reset = 0
        }
        return best
    }

    /// Start of each of the last seven local days, oldest first; plus tomorrow.
    static func dayStarts(now: Date, calendar: Calendar) -> [Int] {
        let today = calendar.startOfDay(for: now)
        return (-6...1).map { Int(calendar.date(byAdding: .day, value: $0, to: today)!.timeIntervalSince1970) }
    }

    /// Tokens per local day (7 values, today last) for a set of buckets.
    public static func week(_ hours: [HourBucket], now: Date, calendar: Calendar) -> [Int] {
        let starts = dayStarts(now: now, calendar: calendar)
        var week = [Int](repeating: 0, count: 7)
        for b in hours {
            let t = b.hour * 3600
            guard t >= starts[0], t < starts[7] else { continue }
            week[starts.lastIndex(where: { $0 <= t })!] += b.tok
        }
        return week
    }

    /// Merge every host's report into the message for the display.
    public static func merge(_ reports: [HostReport], now: Date, timeZone: TimeZone) -> UsagePayload {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let nowS = Int(now.timeIntervalSince1970)
        let all = reports.flatMap(\.hours)
        let todayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let todays = all.filter { $0.hour * 3600 >= todayStart && $0.hour * 3600 <= nowS }
        var outByModel: [String: Int] = [:]
        for b in todays { outByModel[b.model, default: 0] += b.out }
        // ties broken by name so the result is stable
        let top = outByModel.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        return UsagePayload(
            ts: nowS,
            tz: timeZone.secondsFromGMT(for: now),
            h5: newest(reports.map(\.h5), now: nowS),
            d7: newest(reports.map(\.d7), now: nowS),
            today: .init(tok: todays.reduce(0) { $0 + $1.tok },
                         out: todays.reduce(0) { $0 + $1.out },
                         msgs: todays.reduce(0) { $0 + $1.msgs }),
            week: week(all, now: now, calendar: calendar),
            model: prettyModel(top))
    }
}
