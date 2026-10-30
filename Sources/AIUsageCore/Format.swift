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

    /// "in 3h 12m" / "in 2d 4h".
    public static func countdown(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(m, 1))m"
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

    public static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "claude_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }
}
