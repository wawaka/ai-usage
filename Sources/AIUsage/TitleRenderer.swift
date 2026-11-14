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
        var exhausted = false
    }

    struct Segment {
        var provider: ProviderKind
        var badge: Int?
        var bars: [Bar]
        /// Fixed inner (7d) and outer (5h) slots; missing windows keep their position.
        var dialBars: [Bar?]
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

    static func segments(for statuses: [AccountStatus], remaining: Bool, now: Date = Date()) -> [Segment] {
        let counts = Dictionary(grouping: statuses, by: \.account.provider).mapValues(\.count)
        var seen: [ProviderKind: Int] = [:]
        return statuses.map { s in
            let p = s.account.provider
            seen[p, default: 0] += 1
            let windows = s.snapshot?.windows ?? []
            let five = windows.first { $0.kind == .fiveHour }, seven = windows.first { $0.kind == .sevenDay }
            var shown = [five, seven].compactMap { $0 }
            if shown.isEmpty { shown = Array(windows.prefix(2)) }
            func bar(for w: UsageWindow) -> Bar {
                let d = w.display(remaining: remaining, now: now)
                return Bar(percent: d.percent, onPace: w.paceSplit(remaining: remaining, now: now).onPace, time: d.time, untouched: w.isUntouched, exhausted: w.usedPercent >= 100)
            }
            var bars = shown.map { bar(for: $0) }
            let balance = s.snapshot?.balance
            // Balance-only providers get one full bar, like the reference (green when available).
            if bars.isEmpty, let balance { bars = [Bar(percent: balance.isAvailable ? 100 : 0, onPace: balance.isAvailable ? 100 : 0)] }
            if bars.isEmpty { bars = [Bar(percent: 0, onPace: 0)] }
            return Segment(provider: p, badge: (counts[p] ?? 0) > 1 ? seen[p] : nil, bars: bars,
                           dialBars: (five != nil || seven != nil) ? [seven.map { bar(for: $0) }, five.map { bar(for: $0) }] : [bars.first, nil],
                           percents: [five, seven].compactMap { $0?.display(remaining: remaining, now: now).percent },
                           state: s.error != nil && s.snapshot == nil ? .unavailable : s.analysis?.state,
                           balanceText: balance?.formatted)
        }
    }

    static func text(for seg: Segment) -> String? {
        if !seg.percents.isEmpty { return seg.percents.map(Format.percent).joined(separator: "·") }
        return seg.balanceText
    }

    static func width(of seg: Segment, configuration: DisplayStyleSettings) -> CGFloat {
        let style = configuration.style
        if style == .dials { return height }
        if style == .verticalBars { return height / 2 }
        var w = iconSize
        if style != .percent { w += iconBarGap + barWidth }
        if style == .percent || configuration.horizontal.showPercent, let t = text(for: seg) {
            w += iconBarGap + ceil(NSAttributedString(string: t, attributes: [.font: percentFont]).size().width)
        }
        return w
    }

    static func image(for segs: [Segment], configuration: DisplayStyleSettings) -> NSImage {
        let style = configuration.style
        if style == .dials { return dialImage(for: segs, options: configuration.dial) }
        if style == .verticalBars { return verticalImage(for: segs, options: configuration.vertical) }
        let widths = segs.map { width(of: $0, configuration: configuration) }
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
                        if bar.percent > 0 || bar.exhausted { fillBar(bar, flat: bar.untouched || seg.state == .unavailable, at: NSPoint(x: x, y: y)) }
                        // Usage refresh guide: usage reaching past the cursor = ahead of the window's pace.
                        if configuration.horizontal.showPace, let time = bar.time {
                            drawGuide(atX: x + barWidth * min(max(time, 0), 1), barY: y, dark: dark)
                        }
                        y -= barHeight + barGap
                    }
                    x += barWidth
                }
                if style == .percent || configuration.horizontal.showPercent, let t = text(for: seg) {
                    x += iconBarGap
                    let s = NSAttributedString(string: t, attributes: [.font: percentFont, .foregroundColor: style == .percent && !configuration.numbers.colorByUsage ? NSColor.labelColor : fill])
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

    /// Half-height-wide tiles with a semicircular provider mark beneath two vertical meters.
    static func verticalImage(for segments: [Segment], options: VerticalBarSettings) -> NSImage {
        let logosOnTop = options.logosOnTop
        let tileWidth = height / 2
        let image = NSImage(size: NSSize(width: max(1, CGFloat(segments.count) * tileWidth), height: height), flipped: false) { _ in
            let dark = Theme.isDark(nil)
            let ink = dark ? NSColor.white : NSColor.black
            for (index, segment) in segments.enumerated() {
                let x = CGFloat(index) * tileWidth
                NSGraphicsContext.saveGraphicsState()
                // Keep artwork upright; choose the upper or lower semicircle.
                let markY: CGFloat = logosOnTop ? height - 10 : 1
                let cropY: CGFloat = logosOnTop ? height - 5.5 : 1
                let markRect = NSRect(x: x + 1, y: markY, width: 9, height: 9)
                NSBezierPath(ovalIn: markRect).addClip()
                NSBezierPath(rect: NSRect(x: x + 1, y: cropY, width: 9, height: 4.5)).addClip()
                NSGraphicsContext.current?.cgContext.setAlpha(0.65)
                Theme.drawMark(segment.provider, in: markRect)
                NSGraphicsContext.restoreGraphicsState()

                // Dial slots are [7d, 5h]; vertical meters read [5h, 7d].
                for (slot, bar) in segment.dialBars.reversed().enumerated() {
                    let rect = NSRect(x: x + 1 + CGFloat(slot) * 5, y: logosOnTop ? 1 : 6.5, width: 4, height: height - 7.5)
                    ink.withAlphaComponent(0.12).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                    guard let bar else { continue }
                    let fraction = min(max(bar.exhausted ? 1 : bar.percent / 100, 0), 1)
                    let fillRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).addClip()
                    NSGraphicsContext.current?.cgContext.setAlpha(0.8)
                    if bar.exhausted || bar.untouched || segment.state == .unavailable {
                        (bar.exhausted ? Theme.exhausted : Theme.muted).setFill()
                        fillRect.fill()
                    } else {
                        Theme.warning.setFill()
                        fillRect.fill()
                        Theme.ok.setFill()
                        NSRect(x: rect.minX, y: rect.minY, width: rect.width,
                               height: rect.height * min(max(bar.onPace / 100, 0), fraction)).fill()
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    if options.showPace, let time = bar.time {
                        let y = rect.minY + rect.height * min(max(time, 0), 1)
                        ink.withAlphaComponent(0.65).setFill()
                        NSRect(x: rect.minX, y: min(rect.maxY - 0.5, max(rect.minY, y - 0.25)), width: rect.width, height: 0.5).fill()
                    }
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// One square per account. Concentric rings run clockwise from twelve o'clock.
    static func dialImage(for segments: [Segment], options: DialSettings) -> NSImage {
        let image = NSImage(size: NSSize(width: max(1, CGFloat(segments.count) * height), height: height), flipped: false) { _ in
            let dark = Theme.isDark(nil)
            let track = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.22)
            for (index, segment) in segments.enumerated() {
                let center = NSPoint(x: CGFloat(index) * height + height / 2, y: height / 2)
                Theme.drawMark(segment.provider, in: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8), badge: segment.badge)
                for (slot, bar) in segment.dialBars.enumerated() {
                    let radius: CGFloat = slot == 0 ? 6.75 : 9.25
                    func arc(from start: Double, to end: Double, color: NSColor) {
                        guard end > start else { return }
                        let path = NSBezierPath()
                        path.appendArc(withCenter: center, radius: radius,
                                       startAngle: CGFloat(90 - start * 360), endAngle: CGFloat(90 - end * 360), clockwise: true)
                        path.lineWidth = 2.0
                        path.lineCapStyle = .butt
                        color.setStroke()
                        path.stroke()
                    }
                    arc(from: 0, to: 1, color: track)
                    guard let bar else { continue }
                    let fraction = min(max(bar.exhausted ? 1 : bar.percent / 100, 0), 1)
                    if bar.exhausted || bar.untouched || segment.state == .unavailable {
                        arc(from: 0, to: fraction, color: bar.exhausted ? Theme.exhausted : Theme.muted)
                    } else {
                        let good = min(max(bar.onPace / 100, 0), fraction)
                        arc(from: 0, to: good, color: Theme.ok)
                        arc(from: good, to: fraction, color: Theme.warning)
                    }
                    if options.showPace, let time = bar.time {
                        let angle = (90 - min(max(time, 0), 1) * 360) * Double.pi / 180
                        let guide = NSBezierPath()
                        for (i, r) in [radius - 1.25, radius + 1.25].enumerated() {
                            let point = NSPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
                            if i == 0 { guide.move(to: point) } else { guide.line(to: point) }
                        }
                        guide.lineWidth = 0.75
                        (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.65).setStroke()
                        guide.stroke()
                    }
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
        let width = max(barRadius * 2, (barWidth * (bar.exhausted ? 100 : min(bar.percent, 100)) / 100).rounded())
        let rect = NSRect(x: origin.x, y: origin.y, width: width, height: barHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: barRadius, yRadius: barRadius)
        if bar.exhausted {
            Theme.exhausted.setFill()
            path.fill()
            return
        }
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
