import Foundation

public enum Format {
    /// "64%" (no decimals; values under 1 but above 0 show as "<1%").
    public static func percent(_ v: Double) -> String {
        v > 0 && v < 1 ? "<1%" : "\(Int(v.rounded()))%"
    }

    /// "reset 17:10" today, "reset 9/1 22:15" later, "reset due" when passed.
    public static func reset(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if date <= now { return "reset due" }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return "reset \(time.string(from: date))"
    }

    /// Time left until `date`, at most two non-zero components: "2d 5h", "2d 5m", "3h 12m", "7m".
    public static func countdown(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let parts = [(secs / 86400, "d"), ((secs % 86400) / 3600, "h"), ((secs % 3600) / 60, "m")]
            .filter { $0.0 > 0 }
            .prefix(2)
            .map { "\($0.0)\($0.1)" }
        return parts.isEmpty ? "<1m" : parts.joined(separator: " ")
    }

    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Highest usage across the main windows (what the compact title shows).
    public static func bindingPercent(_ snapshot: UsageSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        return snapshot.windows.map(\.usedPercent).max()
    }

    /// The headline number: highest used%, or (inverted) the lowest remaining%.
    public static func headlinePercent(_ snapshot: UsageSnapshot?, remaining: Bool) -> Double? {
        bindingPercent(snapshot).map { remaining ? 100 - $0 : $0 }
    }

    public static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "claude_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
