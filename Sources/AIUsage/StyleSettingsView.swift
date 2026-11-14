import AIUsageCore
import SwiftUI

struct StyleSettingsView: View {
    @Binding var configuration: DisplayStyleSettings

    var body: some View {
        switch configuration.style {
        case .bars: HorizontalBarsSettingsView(options: $configuration.horizontal)
        case .verticalBars: VerticalBarsSettingsView(options: $configuration.vertical)
        case .dials: DialSettingsView(options: $configuration.dial)
        case .percent: NumberSettingsView(options: $configuration.numbers)
        }
    }
}

private struct HorizontalBarsSettingsView: View {
    @Binding var options: HorizontalBarSettings

    var body: some View {
        Toggle("Show percentages beside bars", isOn: $options.showPercent)
        Toggle("Show pace markers", isOn: $options.showPace)
        Text("5-hour usage is above 7-day usage. Pace markers show how far each window has run toward its reset.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct VerticalBarsSettingsView: View {
    @Binding var options: VerticalBarSettings

    var body: some View {
        Toggle("Logos on top", isOn: $options.logosOnTop)
        Toggle("Show pace markers", isOn: $options.showPace)
        Text("Meters fill upward: 5-hour usage on the left, 7-day usage on the right. Provider logos sit above or below the meters.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct DialSettingsView: View {
    @Binding var options: DialSettings

    var body: some View {
        Toggle("Show pace markers", isOn: $options.showPace)
        Text("Rings fill clockwise from twelve: 7-day usage inside, 5-hour usage outside. Providers without these windows show their available quota in the inner ring.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct NumberSettingsView: View {
    @Binding var options: NumberSettings

    var body: some View {
        Toggle("Color numbers by usage", isOn: $options.colorByUsage)
        Text("5-hour and 7-day percentages appear beside the provider logo. Usage colors are green on pace and amber when ahead of pace.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
