import AppKit
import SwiftUI

/// A continuous track and freely moving thumb; only the emitted setting is quantized.
struct SmoothSteppedSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SmoothSlider {
        let slider = SmoothSlider()
        slider.cell = SmoothSliderCell()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.committedValue = value
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Menu bar length")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: SmoothSlider, context: Context) {
        context.coordinator.parent = self
        slider.committedValue = value
        // Don't pull the thumb back onto a step while the mouse is still tracking.
        if !slider.isDragging { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: SmoothSteppedSlider
        init(_ parent: SmoothSteppedSlider) { self.parent = parent }

        @objc func changed(_ slider: NSSlider) {
            let lower = parent.range.lowerBound
            let snapped = lower + ((slider.doubleValue - lower) / parent.step).rounded() * parent.step
            let value = min(parent.range.upperBound, max(lower, snapped))
            (slider as? SmoothSlider)?.committedValue = value
            if parent.value != value { parent.value = value }
        }
    }
}

final class SmoothSlider: NSSlider {
    private(set) var isDragging = false
    var committedValue: Double = 0

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        defer {
            isDragging = false
            doubleValue = committedValue
        }
        super.mouseDown(with: event)
    }
}

/// Keep both sides of the track the same thickness, without native tick cutouts.
private final class SmoothSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let path = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.controlAccentColor.setFill()
        let end = min(track.maxX, max(track.minX, knobRect(flipped: flipped).midX))
        NSRect(x: track.minX, y: track.minY, width: end - track.minX, height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
