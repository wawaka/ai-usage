import Foundation

/// One observation of a usage window: when, how much was used, and the reset it was counting down to.
public struct UsageSample: Equatable, Sendable {
    public var at: Date
    public var percent: Double
    public var resetsAt: Date?

    public init(at: Date, percent: Double, resetsAt: Date?) {
        // Stored to the second and 0.1 %, which is all the providers report anyway.
        self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded())
        self.percent = (min(max(percent, 0), 100) * 10).rounded() / 10
        self.resetsAt = resetsAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) }
    }

    /// Same numbers (the time aside): the reset compared within `UsageWindow.fullWindowTolerance`.
    func sameValue(as other: UsageSample) -> Bool {
        guard percent == other.percent else { return false }
        switch (resetsAt, other.resetsAt) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= UsageWindow.fullWindowTolerance
        default: return false
        }
    }
}

/// Encoded compactly as `[seconds, percent]` or `[seconds, percent, resetSeconds]`: the history file
/// holds weeks of samples.
extension UsageSample: Codable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let at = try c.decode(Double.self)
        let percent = try c.decode(Double.self)
        let reset = c.isAtEnd ? nil : try c.decodeNil() ? nil : try c.decode(Double.self)
        self.init(at: Date(timeIntervalSince1970: at), percent: percent, resetsAt: reset.map(Date.init(timeIntervalSince1970:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(Int64(at.timeIntervalSince1970))
        try c.encode(percent)
        if let resetsAt { try c.encode(Int64(resetsAt.timeIntervalSince1970)) }
    }
}

/// Every recorded sample of one window ("5h", "7d", "7d Opus"…) of one account, oldest first.
public struct WindowHistory: Codable, Equatable, Sendable {
    public var windowMinutes: Int?
    public var samples: [UsageSample]

    public init(windowMinutes: Int? = nil, samples: [UsageSample] = []) {
        self.windowMinutes = windowMinutes
        self.samples = samples
    }

    /// Appends a sample. A run of equal values keeps only its first and last sample, so a window
    /// that sits unchanged for hours costs two entries, and its flat stretch still shows when it ended.
    mutating func append(_ sample: UsageSample) {
        if let last = samples.last, sample.at <= last.at { return }
        if samples.count >= 2, sample.sameValue(as: samples[samples.count - 1]), sample.sameValue(as: samples[samples.count - 2]) {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
    }

    /// The samples split into the window's intervals (oldest first), each from its start (a window
    /// length before its reset) to its reset. A new interval begins when the reset moves, when a
    /// sample comes after the previous interval's reset, or, without a known reset, when usage drops.
    public func intervals() -> [UsageInterval] {
        var result: [UsageInterval] = []
        var current: [UsageSample] = []
        func close() {
            guard let first = current.first else { return }
            let end = current.last?.resetsAt
            let length = windowMinutes.map { TimeInterval($0) * 60 }
            let start = end.flatMap { e in length.map { e.addingTimeInterval(-$0) } }.map { min($0, first.at) } ?? first.at
            result.append(UsageInterval(start: start, end: end, windowMinutes: windowMinutes, samples: current))
            current = []
        }
        for sample in samples {
            if let last = current.last {
                let tolerance = UsageWindow.fullWindowTolerance
                let moved = both(last.resetsAt, sample.resetsAt).map { abs($0.timeIntervalSince($1)) > tolerance } ?? false
                let passed = last.resetsAt.map { sample.at >= $0 } ?? false
                let dropped = (last.resetsAt == nil || sample.resetsAt == nil) && sample.percent < last.percent - 0.5
                if moved || passed || dropped { close() }
            }
            current.append(sample)
        }
        close()
        return result
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// One window period: from its start to the reset that ends it.
public struct UsageInterval: Equatable, Sendable {
    /// A window length before `end`, or the first sample when the reset or length is unknown.
    public var start: Date
    /// The reset that ends the interval, if the provider reported one.
    public var end: Date?
    public var windowMinutes: Int?
    public var samples: [UsageSample]

    /// Highest usage seen in the interval.
    public var peak: Double { samples.map(\.percent).max() ?? 0 }

    /// Where the chart's time axis ends: the reset, else the last sample (or `now` while it's current).
    public func axisEnd(now: Date) -> Date {
        if let end { return max(end, start.addingTimeInterval(60)) }
        return max(samples.last?.at ?? start, now, start.addingTimeInterval(60))
    }

    /// Whether `now` falls inside the interval.
    public func isCurrent(now: Date) -> Bool { end.map { now < $0 } ?? true }
}

/// Usage history of every account, kept in `history.json` in AI Usage's own directory.
public struct UsageHistory: Codable, Equatable, Sendable {
    /// Account ID → window label → samples.
    public var accounts: [String: [String: WindowHistory]] = [:]

    /// How long samples are kept: four weeks of 7-day windows plus slack.
    public static let retention: TimeInterval = 35 * 86400

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([String: [String: WindowHistory]].self, forKey: .accounts) ?? [:]
    }

    public func windows(_ accountID: String) -> [String: WindowHistory] { accounts[accountID] ?? [:] }

    /// Records every started window of a fresh snapshot (an untouched window has no interval yet),
    /// as observed at `date` (default: the snapshot's `observedAt`).
    public mutating func record(_ snapshot: UsageSnapshot, for accountID: String, at date: Date? = nil) {
        var windows = accounts[accountID] ?? [:]
        for w in snapshot.windows + snapshot.extraWindows where !w.isUntouched {
            var h = windows[w.label] ?? WindowHistory()
            if let minutes = w.windowMinutes { h.windowMinutes = minutes }
            h.append(UsageSample(at: date ?? snapshot.observedAt, percent: w.usedPercent, resetsAt: w.resetsAt))
            windows[w.label] = h
        }
        accounts[accountID] = windows
    }

    /// Drops samples older than `retention` (and windows/accounts left empty).
    public mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        for (id, windows) in accounts {
            let kept = windows.compactMapValues { h -> WindowHistory? in
                var h = h
                h.samples.removeAll { $0.at < cutoff }
                return h.samples.isEmpty ? nil : h
            }
            accounts[id] = kept.isEmpty ? nil : kept
        }
    }

    public mutating func remove(_ accountID: String) { accounts[accountID] = nil }
}
