import AIUsageCore
import SwiftUI

/// Which window's chart is open in the dropdown (at most one at a time), and how many intervals
/// back from the latest it shows.
@MainActor
final class ChartSelection: ObservableObject {
    @Published var key: String?
    @Published var back = 0

    static func key(_ accountID: String, _ label: String) -> String { "\(accountID)|\(label)" }

    func toggle(_ key: String) {
        if self.key == key {
            self.key = nil
        } else {
            self.key = key
            back = 0
        }
    }
}

/// Mouse position over a chart (x in the chart's coordinates), nil when the mouse is outside.
final class HoverLocation: ObservableObject {
    @Published var x: CGFloat?
}

/// Opened by clicking a window's bar: the chart of one interval of that window, ‹ › to step
/// through earlier intervals, and a strip with every recorded interval's peak to jump to one.
struct UsageChartPanel: View {
    let history: WindowHistory?
    let now: Date
    let remaining: Bool
    @ObservedObject var selection: ChartSelection

    var body: some View {
        let intervals = history?.intervals() ?? []
        Group {
            if intervals.isEmpty {
                Text("No history yet. Usage is recorded from now on, at every update.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let index = intervals.count - 1 - min(max(selection.back, 0), intervals.count - 1)
                content(intervals, index)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func content(_ intervals: [UsageInterval], _ index: Int) -> some View {
        let interval = intervals[index]
        let end = interval.axisEnd(now: now)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                StepButton(symbol: "chevron.left", enabled: index > 0, help: "Previous interval") { selection.back += 1 }
                Text("\(Format.stamp(interval.start, now: now)) – \(Format.stamp(end, now: now))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                StepButton(symbol: "chevron.right", enabled: index < intervals.count - 1, help: "Next interval") { selection.back -= 1 }
                Spacer(minLength: 4)
                Text(summary(interval))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            UsageChart(interval: interval, now: now, remaining: remaining)
                .frame(height: 100)
            if intervals.count > 1 {
                IntervalStrip(intervals: intervals, selected: index, now: now) { selection.back = intervals.count - 1 - $0 }
            }
        }
    }

    private func summary(_ interval: UsageInterval) -> String {
        let peak = interval.peak
        let current = interval.isCurrent(now: now)
        if remaining { return "\(current ? "now" : "lowest") \(Format.percent(100 - (current ? interval.samples.last?.percent ?? peak : peak))) left" }
        return current ? "now \(Format.percent(interval.samples.last?.percent ?? peak))" : "peak \(Format.percent(peak))"
    }
}

private struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
        .help(help)
    }
}

/// One bar per recorded interval (height = its peak usage), separated so each interval reads as
/// its own block; the open one is highlighted. Click a bar to open that interval.
private struct IntervalStrip: View {
    let intervals: [UsageInterval]
    let selected: Int
    let now: Date
    let pick: (Int) -> Void
    private let shown = 30

    var body: some View {
        // Keep the open interval in view while stepping back through long histories.
        let hi = selected >= intervals.count - shown ? intervals.count : min(intervals.count, selected + shown / 2)
        let lo = max(0, hi - shown)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(lo..<hi, id: \.self) { i in
                let interval = intervals[i]
                let color = i == selected ? Color.accentColor
                    : interval.peak >= 100 ? Color(nsColor: Theme.exhausted).opacity(0.6) : Color.secondary.opacity(0.35)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 1.5).fill(color)
                        .frame(height: max(2, 16 * interval.peak / 100))
                }
                .frame(maxWidth: 14, minHeight: 18, maxHeight: 18)
                .contentShape(Rectangle())
                .onTapGesture { pick(i) }
                .help("\(Format.stamp(interval.start, now: now)) – \(Format.stamp(interval.axisEnd(now: now), now: now)) · peak \(Format.percent(interval.peak))")
            }
            if hi - lo < shown { Spacer(minLength: 0) }
        }
        .frame(height: 18)
    }
}

/// Usage over one interval. The x axis spans exactly the interval (its start and reset are drawn as
/// solid bounds, days of a long window as faint separators); the dashed diagonal is the even pace
/// that would use the whole quota by the reset, and usage above it is drawn amber like the meters.
/// The part of a current interval still to come is shaded, with a "now" line.
struct UsageChart: View {
    let interval: UsageInterval
    let now: Date
    let remaining: Bool
    @StateObject private var hover = HoverLocation()

    var body: some View {
        let hoverX = hover.x
        Canvas { ctx, size in draw(&ctx, size: size, hoverX: hoverX) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover.x = p.x
                case .ended: hover.x = nil
                }
            }
    }

    private static let labelWidth: CGFloat = 26

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, hoverX: CGFloat?) {
        let plot = CGRect(x: 0, y: 5, width: max(1, size.width - Self.labelWidth), height: max(1, size.height - 10))
        let start = interval.start
        let end = interval.axisEnd(now: now)
        let span = max(end.timeIntervalSince(start), 1)
        func x(_ t: Date) -> CGFloat { plot.minX + CGFloat(min(max(t.timeIntervalSince(start) / span, 0), 1)) * plot.width }
        func y(_ used: Double) -> CGFloat {
            let v = remaining ? 100 - used : used
            return plot.maxY - CGFloat(min(max(v, 0), 100) / 100) * plot.height
        }
        let faint = Color.primary.opacity(0.10)
        let label = Color.secondary

        // Grid and y labels.
        for v in [0.0, 50, 100] {
            let yy = plot.maxY - CGFloat(v / 100) * plot.height
            ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: yy)); $0.addLine(to: CGPoint(x: plot.maxX, y: yy)) },
                       with: .color(faint), lineWidth: 0.5)
            ctx.draw(Text("\(Int(v))%").font(.system(size: 9).monospacedDigit()).foregroundColor(label),
                     at: CGPoint(x: plot.maxX + 3, y: yy), anchor: .leading)
        }

        // Day separators for windows longer than a day, with the weekday at the top of each day.
        if span > 36 * 3600 {
            let calendar = Calendar.current
            var day = calendar.startOfDay(for: start)
            let weekday = DateFormatter()
            weekday.locale = Locale(identifier: "en_US_POSIX")
            weekday.dateFormat = "EEE"
            while day < end {
                let next = calendar.date(byAdding: .day, value: 1, to: day) ?? end
                if day > start {
                    let xx = x(day)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.minY)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY)) },
                               with: .color(faint), lineWidth: 0.5)
                }
                let mid = x(max(day, start)) + (x(min(next, end)) - x(max(day, start))) / 2
                if x(min(next, end)) - x(max(day, start)) > 22 {
                    ctx.draw(Text(weekday.string(from: day)).font(.system(size: 8)).foregroundColor(label.opacity(0.7)),
                             at: CGPoint(x: mid, y: plot.minY + 1), anchor: .top)
                }
                day = next
            }
        }

        // Still to come in a current interval: shaded, after a "now" line.
        let current = interval.isCurrent(now: now) && now < end
        if current {
            let nx = x(now)
            ctx.fill(Path(CGRect(x: nx, y: plot.minY, width: plot.maxX - nx, height: plot.height)), with: .color(Color.primary.opacity(0.05)))
            ctx.stroke(Path { $0.move(to: CGPoint(x: nx, y: plot.minY)); $0.addLine(to: CGPoint(x: nx, y: plot.maxY)) },
                       with: .color(Color.primary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }

        // Interval bounds: where the window started and where it resets.
        for xx in [plot.minX + 0.5, plot.maxX - 0.5] {
            ctx.stroke(Path { $0.move(to: CGPoint(x: xx, y: plot.minY)); $0.addLine(to: CGPoint(x: xx, y: plot.maxY)) },
                       with: .color(Color.primary.opacity(0.4)), lineWidth: 1)
        }

        // Even pace: from nothing used at the start to everything used at the reset.
        let pace: Path? = interval.end != nil && interval.windowMinutes != nil ? Path {
            $0.move(to: CGPoint(x: plot.minX, y: y(0)))
            $0.addLine(to: CGPoint(x: plot.maxX, y: y(100)))
        } : nil
        if let pace {
            ctx.stroke(pace, with: .color(Color.primary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Usage: each observation, held to now (current) or the reset (past) after the last one.
        let samples = interval.samples
        guard let first = samples.first, let last = samples.last else { return }
        var points = samples.map { CGPoint(x: x($0.at), y: y($0.percent)) }
        let tail = current ? now : end
        if tail > last.at { points.append(CGPoint(x: x(tail), y: y(last.percent))) }
        var line = Path()
        line.addLines(points)
        var area = line
        area.addLine(to: CGPoint(x: points.last!.x, y: y(remaining ? 100 : 0)))
        area.addLine(to: CGPoint(x: points[0].x, y: y(remaining ? 100 : 0)))
        area.closeSubpath()

        let exhausted = interval.peak >= 100
        let good = Color(nsColor: exhausted ? Theme.exhausted : Theme.ok)
        let ahead = Color(nsColor: exhausted ? Theme.exhausted : Theme.warning)
        ctx.fill(area, with: .color(good.opacity(0.16)))
        ctx.stroke(line, with: .color(good), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        if pace != nil {
            // Above the pace line (below it when showing what's left) the line turns amber.
            var aheadRegion = Path()
            aheadRegion.move(to: CGPoint(x: plot.minX, y: y(0)))
            aheadRegion.addLine(to: CGPoint(x: plot.maxX, y: y(100)))
            aheadRegion.addLine(to: CGPoint(x: plot.maxX, y: remaining ? plot.maxY + 2 : plot.minY - 2))
            aheadRegion.addLine(to: CGPoint(x: plot.minX, y: remaining ? plot.maxY + 2 : plot.minY - 2))
            aheadRegion.closeSubpath()
            ctx.drawLayer { layer in
                layer.clip(to: aheadRegion)
                layer.stroke(line, with: .color(ahead), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        if samples.count == 1 {
            ctx.fill(Path(ellipseIn: CGRect(x: points[0].x - 2, y: points[0].y - 2, width: 4, height: 4)), with: .color(good))
        }

        // Hover: the value at the mouse, as last observed at or before that moment.
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX else { return }
        let t = start.addingTimeInterval(Double((hx - plot.minX) / plot.width) * span)
        ctx.stroke(Path { $0.move(to: CGPoint(x: hx, y: plot.minY)); $0.addLine(to: CGPoint(x: hx, y: plot.maxY)) },
                   with: .color(Color.primary.opacity(0.5)), lineWidth: 0.5)
        var text = Format.stamp(t, now: now)
        if t >= first.at, t <= max(tail, last.at), let sample = samples.last(where: { $0.at <= t }) {
            let v = remaining ? 100 - sample.percent : sample.percent
            text += " · \(Format.percent(v))\(remaining ? " left" : "")"
            ctx.fill(Path(ellipseIn: CGRect(x: hx - 2.5, y: y(sample.percent) - 2.5, width: 5, height: 5)), with: .color(good))
        }
        let resolved = ctx.resolve(Text(text).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(.primary))
        let textSize = resolved.measure(in: size)
        let box = CGRect(x: min(max(hx - textSize.width / 2 - 4, 0), size.width - textSize.width - 8),
                         y: 0, width: textSize.width + 8, height: textSize.height + 2)
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 3), with: .color(faint), lineWidth: 0.5)
        ctx.draw(resolved, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}
