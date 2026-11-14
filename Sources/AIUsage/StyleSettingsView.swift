import AIUsageCore
import SwiftUI

struct StyleSettingsView: View {
    @Binding var configuration: DisplayStyleSettings

    var body: some View {
        switch configuration.style {
        case .bars: HorizontalBarsSettingsView(options: $configuration.horizontal)
        case .verticalBars: VerticalBarsSettingsView(options: $configuration.vertical)
        case .dials: DialSettingsView(options: $configuration.dial)
        case .percent: NumberSettingsView()
        }
    }
}

private struct HorizontalBarsSettingsView: View {
    @Binding var options: HorizontalBarSettings

    var body: some View {
        Toggle("Show pace markers", isOn: $options.showPace)
        Text("5-hour usage is above 7-day usage. Pace markers show how far each window has run toward its reset.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct VerticalBarsSettingsView: View {
    @Binding var options: VerticalBarSettings

    var body: some View {
        Picker("Logo position", selection: $options.logoPosition) {
            ForEach(LogoPosition.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Show pace markers", isOn: $options.showPace)
        Text("Meters fill upward: 5-hour usage on the left, 7-day usage on the right. Choose a half-logo above, below or beside each pair of meters, or hide logos.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct DialSettingsView: View {
    @Binding var options: DialSettings

    var body: some View {
        Toggle("Show pace markers", isOn: $options.showPace)
        Stepper("Ring width: \(options.effectiveRingWidth, specifier: "%.2f") pt", value: $options.ringWidth, in: 1...2.5, step: 0.25)
        Stepper("Ring gap: \(options.effectiveRingGap, specifier: "%.2f") pt", value: $options.ringGap, in: 0.5...1, step: 0.25)
        Stepper("Logo size: \(options.effectiveIconSize, specifier: "%.0f") pt", value: $options.iconSize, in: 4...8, step: 1)
        Text("Rings fill clockwise from twelve: 7-day usage inside, 5-hour usage outside. Providers without these windows show their available quota in the inner ring.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct NumberSettingsView: View {
    var body: some View {
        Text("5-hour usage is on top and 7-day usage below, beside each provider logo. Colors follow the meters: green on pace, amber ahead of pace, red when exhausted and grey for untouched or unavailable data.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
