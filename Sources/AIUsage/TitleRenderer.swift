import AIUsageCore
import AppKit

/// Draws the menu bar title: one segment per account (mark + stacked 5h/7d bars), separated by
/// thin dividers — the coding-usage-bar look, drawn natively and re-resolved for light/dark.
enum TitleRenderer {
    // Geometry from coding-usage-bar's title payload.
    static let height: CGFloat = 22
    static let iconSize: CGFloat = 16
    static let iconBarGap: CGFloat = 4
    static let segmentGap: CGFloat = 8
    static let barWidth: CGFloat = 48
    static let barHeight: CGFloat = 4
    static let barGap: CGFloat = 3
    static let barRadius: CGFloat = 2
    static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    struct Bar {
        var percent: Double
        /// Part of `percent` that is on pace (green); the rest is ahead of the window's pace (amber).
        var onPace: Double
        /// Fraction of the window's time elapsed (or left, when showing remaining); drawn as an I-beam cursor.
        var time: Double?
        /// Window not started yet: drawn grey, without a cursor.
        var untouched = false
    }

    struct Segment {
        var provider: ProviderKind
        var badge: Int?
        var bars: [Bar]
        var percents: [Double]
        var state: UsageState?
        var balanceText: String?

        /// Usage ahead of the window's pace on any bar.
        var ahead: Bool { bars.contains { $0.percent > $0.onPace } }

        /// Percent text colour: green on pace, amber when ahead; balance and error states keep their own.
        var textColor: NSColor {
            switch state {
            case .unavailable, .balance, .depleted, .none: return Theme.color(for: state)
            default: return ahead ? Theme.warning : Theme.ok
            }
        }
    }

    static func segments(for statuses: [AccountStatus], remaining: Bool) -> [Segment] {
        let counts = Dictionary(grouping: statuses, by: \.account.provider).mapValues(\.count)
        var seen: [ProviderKind: Int] = [:]
        return statuses.map { s in
            let p = s.account.provider
            seen[p, default: 0] += 1
            let windows = s.snapshot?.windows ?? []
            let five = windows.first { $0.kind == .fiveHour }, seven = windows.first { $0.kind == .sevenDay }
            var shown = [five, seven].compactMap { $0 }
            if shown.isEmpty { shown = Array(windows.prefix(2)) }
            var bars = shown.map { w -> Bar in
                let d = w.display(remaining: remaining)
                return Bar(percent: d.percent, onPace: w.paceSplit(remaining: remaining).onPace, time: d.time, untouched: w.isUntouched)
            }
            let balance = s.snapshot?.balance
            // Balance-only providers get one full bar, like the reference (green when available).
            if bars.isEmpty, let balance { bars = [Bar(percent: balance.isAvailable ? 100 : 0, onPace: balance.isAvailable ? 100 : 0)] }
            if bars.isEmpty { bars = [Bar(percent: 0, onPace: 0)] }
            return Segment(provider: p, badge: (counts[p] ?? 0) > 1 ? seen[p] : nil, bars: bars,
                           percents: [five, seven].compactMap { $0?.display(remaining: remaining).percent },
                           state: s.error != nil && s.snapshot == nil ? .unavailable : s.analysis?.state,
                           balanceText: balance?.formatted)
        }
    }

    static func text(for seg: Segment) -> String? {
        if !seg.percents.isEmpty { return seg.percents.map(Format.percent).joined(separator: "·") }
        return seg.balanceText
    }

    static func width(of seg: Segment, style: TitleStyle) -> CGFloat {
        var w = iconSize
        if style != .percent { w += iconBarGap + barWidth }
        if style != .bars, let t = text(for: seg) {
            w += iconBarGap + ceil(NSAttributedString(string: t, attributes: [.font: percentFont]).size().width)
        }
        return w
    }

    static func image(for segs: [Segment], style: TitleStyle) -> NSImage {
        let widths = segs.map { width(of: $0, style: style) }
        let total = widths.reduce(0, +) + CGFloat(max(0, segs.count - 1)) * (segmentGap * 2 + 1)
        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            let dark = Theme.isDark(nil)
            let barBg = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.25 : 0.3)
            let divider = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.3 : 0.25)
            var x: CGFloat = 0
            for (i, seg) in segs.enumerated() {
                if i > 0 {
                    x += segmentGap
                    divider.setFill()
                    NSRect(x: x, y: floor(height * 0.2), width: 1, height: floor(height * 0.6)).fill()
                    x += 1 + segmentGap
                }
                Theme.drawMark(seg.provider, in: NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize), badge: seg.badge)
                x += iconSize
                let fill = seg.textColor
                if style != .percent {
                    x += iconBarGap
                    let totalH = CGFloat(seg.bars.count) * barHeight + CGFloat(max(0, seg.bars.count - 1)) * barGap
                    var y = floor((height + totalH) / 2) - barHeight
                    for bar in seg.bars {
                        func capsule(_ width: CGFloat, _ color: NSColor) {
                            color.setFill()
                            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(barRadius * 2, width.rounded()), height: barHeight),
                                         xRadius: barRadius, yRadius: barRadius).fill()
                        }
                        capsule(barWidth, barBg)
                        if bar.percent > 0 { fillBar(bar, flat: bar.untouched || seg.state == .unavailable, at: NSPoint(x: x, y: y)) }
                        // Usage refresh guide: usage reaching past the cursor = ahead of the window's pace.
                        if let time = bar.time {
                            drawGuide(atX: x + barWidth * min(max(time, 0), 1), barY: y, dark: dark)
                        }
                        y -= barHeight + barGap
                    }
                    x += barWidth
                }
                if style != .bars, let t = text(for: seg) {
                    x += iconBarGap
                    let s = NSAttributedString(string: t, attributes: [.font: percentFont, .foregroundColor: style == .percent ? NSColor.labelColor : fill])
                    let size = s.size()
                    s.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                    x += ceil(size.width)
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A bar's fill: green up to the point the window's time has reached, amber for what lies past it.
    /// `flat` draws it grey instead (untouched window, or stale data).
    static func fillBar(_ bar: Bar, flat: Bool, at origin: NSPoint) {
        let width = max(barRadius * 2, (barWidth * min(bar.percent, 100) / 100).rounded())
        let rect = NSRect(x: origin.x, y: origin.y, width: width, height: barHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: barRadius, yRadius: barRadius)
        if flat {
            Theme.muted.setFill()
            path.fill()
            return
        }
        Theme.warning.setFill()
        path.fill()
        guard bar.onPace > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        Theme.ok.setFill()
        let goodWidth = bar.onPace >= bar.percent ? width : (barWidth * min(bar.onPace, 100) / 100).rounded()
        NSRect(x: origin.x, y: origin.y, width: goodWidth, height: barHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// I-beam cursor: a hairline stem just taller than the bar with tiny serifs top and bottom,
    /// drawn translucent so it hints at the position without competing with the usage fill.
    static func drawGuide(atX gx: CGFloat, barY: CGFloat, dark: Bool) {
        let cx = (gx * 2).rounded() / 2
        let overhang: CGFloat = 0.5, serif: CGFloat = 1
        let top = barY + barHeight + overhang, bottom = barY - overhang
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: bottom)); p.line(to: NSPoint(x: cx, y: top))
        p.move(to: NSPoint(x: cx - serif, y: top)); p.line(to: NSPoint(x: cx + serif, y: top))
        p.move(to: NSPoint(x: cx - serif, y: bottom)); p.line(to: NSPoint(x: cx + serif, y: bottom))
        p.lineWidth = 0.75
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.55).setStroke()
        p.stroke()
    }

    /// Fallback when nothing fits / nothing is configured: a gauge glyph tinted by the worst state.
    static func iconImage(worst: UsageState?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let base = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "AI Usage")?
            .withSymbolConfiguration(config) ?? NSImage()
        guard let worst, worst != .normal, worst != .balance else {
            base.isTemplate = true
            return base
        }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            Theme.color(for: worst).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    /// Most urgent account: worst state, then highest usage.
    static func mostUrgent(_ statuses: [AccountStatus]) -> AccountStatus? {
        statuses.min { a, b in
            let pa = a.analysis?.state.priority ?? 9, pb = b.analysis?.state.priority ?? 9
            if pa != pb { return pa < pb }
            return (Format.bindingPercent(a.snapshot) ?? 0) > (Format.bindingPercent(b.snapshot) ?? 0)
        }
    }

    /// Room available for our item: right of the notch on notched displays, else half the bar,
    /// minus what the system's own items (clock, Control Center…) typically take.
    static func menuBarBudget() -> CGFloat {
        guard let screen = NSScreen.main else { return 400 }
        let right = screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2
        return right - 240
    }
}
