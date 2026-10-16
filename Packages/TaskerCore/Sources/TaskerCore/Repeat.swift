import Foundation

/// Repetition, compatible with OmniFocus: an RFC 5545 RRULE plus a schedule type.
public struct RepeatRule: Hashable, Sendable, Codable {
    public enum Anchor: String, Sendable, Codable, CaseIterable { case due, deferDate = "defer", planned }

    public var rrule: String
    /// false = repeat on a fixed schedule ("Regularly"); true = "From completion".
    public var fromCompletion: Bool
    public var anchor: Anchor
    public var catchUp: Bool

    public init(rrule: String, fromCompletion: Bool = false, anchor: Anchor = .due, catchUp: Bool = true) {
        self.rrule = rrule; self.fromCompletion = fromCompletion; self.anchor = anchor; self.catchUp = catchUp
    }

    enum CodingKeys: String, CodingKey { case rrule, fromCompletion, anchor, catchUp }
    public init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        rrule = try k.decode(String.self, forKey: .rrule)
        fromCompletion = try k.decodeIfPresent(Bool.self, forKey: .fromCompletion) ?? false
        anchor = try k.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .due
        catchUp = try k.decodeIfPresent(Bool.self, forKey: .catchUp) ?? true
    }

    public var parsed: RRule { RRule(rrule) }

    public var summary: String {
        let r = parsed
        let unit: String = switch r.freq {
        case .minutely: "minute"; case .hourly: "hour"; case .daily: "day"
        case .weekly: "week"; case .monthly: "month"; case .yearly: "year"
        }
        var s = r.interval == 1 ? "Every \(unit)" : "Every \(r.interval) \(unit)s"
        if !r.byDay.isEmpty {
            let names = Calendar.current.shortWeekdaySymbols
            let days = r.byDay.map { d in (d.ordinal.map { $0 == -1 ? "last " : "\($0)th " } ?? "") + names[d.weekday - 1] }
            s += " on " + days.joined(separator: ", ")
        }
        if !r.byMonthDay.isEmpty {
            s += " on day " + r.byMonthDay.map { $0 == -1 ? "last" : String($0) }.joined(separator: ", ")
        }
        if fromCompletion { s += " after completion" }
        return s
    }
}

public struct RRule: Hashable, Sendable {
    public enum Freq: String, Sendable, CaseIterable { case minutely = "MINUTELY", hourly = "HOURLY", daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    public struct Day: Hashable, Sendable {
        public var ordinal: Int?   // e.g. 2 for "2TU", -1 for "-1FR"
        public var weekday: Int    // Calendar weekday: 1 = Sunday
        public init(ordinal: Int?, weekday: Int) { self.ordinal = ordinal; self.weekday = weekday }
    }

    public var freq: Freq = .daily
    public var interval = 1
    public var byDay: [Day] = []
    public var byMonthDay: [Int] = []
    public var bySetPos: [Int] = []

    static let dayCodes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    public init(freq: Freq, interval: Int = 1) { self.freq = freq; self.interval = interval }

    public init(_ string: String) {
        let body = string.replacingOccurrences(of: "RRULE:", with: "")
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].uppercased() {
            case "FREQ": freq = Freq(rawValue: kv[1].uppercased()) ?? .daily
            case "INTERVAL": interval = max(1, Int(kv[1]) ?? 1)
            case "BYDAY":
                byDay = kv[1].split(separator: ",").compactMap { token in
                    let t = String(token)
                    let code = String(t.suffix(2)).uppercased()
                    guard let wd = RRule.dayCodes[code] else { return nil }
                    let ord = Int(t.dropLast(2))
                    return Day(ordinal: ord, weekday: wd)
                }
            case "BYMONTHDAY": byMonthDay = kv[1].split(separator: ",").compactMap { Int($0) }
            case "BYSETPOS": bySetPos = kv[1].split(separator: ",").compactMap { Int($0) }
            default: break
            }
        }
    }

    public var string: String {
        var parts = ["FREQ=\(freq.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if !byDay.isEmpty {
            let inv = Dictionary(uniqueKeysWithValues: RRule.dayCodes.map { ($1, $0) })
            parts.append("BYDAY=" + byDay.map { ($0.ordinal.map(String.init) ?? "") + inv[$0.weekday]! }.joined(separator: ","))
        }
        if !byMonthDay.isEmpty { parts.append("BYMONTHDAY=" + byMonthDay.map(String.init).joined(separator: ",")) }
        if !bySetPos.isEmpty { parts.append("BYSETPOS=" + bySetPos.map(String.init).joined(separator: ",")) }
        return parts.joined(separator: ";")
    }

    /// The first occurrence strictly after `date`, preserving its time of day.
    public func next(after date: Date, calendar cal: Calendar = .current) -> Date {
        switch freq {
        case .minutely: return cal.date(byAdding: .minute, value: interval, to: date)!
        case .hourly: return cal.date(byAdding: .hour, value: interval, to: date)!
        case .daily: return cal.date(byAdding: .day, value: interval, to: date)!
        case .yearly: return cal.date(byAdding: .year, value: interval, to: date)!
        case .weekly:
            let days = Set(byDay.map(\.weekday))
            guard !days.isEmpty else { return cal.date(byAdding: .weekOfYear, value: interval, to: date)! }
            let startWeek = cal.dateInterval(of: .weekOfYear, for: date)!.start
            var d = date
            for _ in 0..<(7 * interval * 2 + 7) {
                d = cal.date(byAdding: .day, value: 1, to: d)!
                let weekIndex = cal.dateComponents([.weekOfYear], from: startWeek, to: d).weekOfYear ?? 0
                if weekIndex % interval == 0 && days.contains(cal.component(.weekday, from: d)) { return d }
            }
            return cal.date(byAdding: .weekOfYear, value: interval, to: date)!
        case .monthly:
            if byMonthDay.isEmpty && byDay.isEmpty {
                return cal.date(byAdding: .month, value: interval, to: date)!
            }
            // Same month first (a later matching day), then subsequent months by interval.
            var monthOffset = 0
            for _ in 0..<(24 * interval + 1) {
                let monthDate = cal.date(byAdding: .month, value: monthOffset, to: firstOfMonth(date, cal))!
                let candidates = occurrences(inMonth: monthDate, time: date, cal).filter { $0 > date }
                if let c = candidates.min() { return c }
                monthOffset += monthOffset == 0 ? interval : interval
            }
            return cal.date(byAdding: .month, value: interval, to: date)!
        }
    }

    private func firstOfMonth(_ d: Date, _ cal: Calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d))!
    }

    private func occurrences(inMonth month: Date, time: Date, _ cal: Calendar) -> [Date] {
        let t = cal.dateComponents([.hour, .minute, .second], from: time)
        let range = cal.range(of: .day, in: .month, for: month)!
        let daysInMonth = range.count
        func at(_ day: Int) -> Date {
            var c = cal.dateComponents([.year, .month], from: month)
            c.day = day; c.hour = t.hour; c.minute = t.minute; c.second = t.second
            return cal.date(from: c)!
        }
        var result: [Date] = []
        for md in byMonthDay {
            let day = md > 0 ? min(md, daysInMonth) : daysInMonth + md + 1
            if day >= 1 { result.append(at(day)) }
        }
        if !byDay.isEmpty {
            var matching: [Date] = []
            var perWeekday: [Int: [Date]] = [:]
            for day in 1...daysInMonth {
                let d = at(day)
                let wd = cal.component(.weekday, from: d)
                perWeekday[wd, default: []].append(d)
            }
            for spec in byDay {
                let list = perWeekday[spec.weekday] ?? []
                if let ord = spec.ordinal {
                    let idx = ord > 0 ? ord - 1 : list.count + ord
                    if list.indices.contains(idx) { matching.append(list[idx]) }
                } else {
                    matching.append(contentsOf: list)
                }
            }
            matching.sort()
            if !bySetPos.isEmpty {
                matching = bySetPos.compactMap { p in
                    let idx = p > 0 ? p - 1 : matching.count + p
                    return matching.indices.contains(idx) ? matching[idx] : nil
                }
            }
            result.append(contentsOf: matching)
        }
        return result
    }
}
