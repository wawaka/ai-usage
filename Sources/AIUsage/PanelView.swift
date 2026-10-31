import AIUsageCore
import SwiftUI

struct PanelActions {
    var openAccounts: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// The dropdown card, modelled on coding-usage-bar's: one section per account with a state badge,
/// the headline percentage, 5h/7d meters (usage + elapsed time) with time left, and data age.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.statuses.isEmpty {
                emptyState.padding(16)
            } else {
                if model.statuses.count > 5 {
                    ScrollView { sections }.frame(height: 560)
                } else {
                    sections
                }
            }
            Divider()
            footer.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 380)
    }

    private var sections: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.statuses.enumerated()), id: \.element.id) { index, status in
                if index > 0 { Divider().padding(.horizontal, 16) }
                AccountSection(status: status, remaining: settings.showRemaining, refreshGuide: settings.refreshGuide,
                               refreshing: model.refreshingIDs.contains(status.id),
                               inMenuBar: Binding(get: { !model.notInMenuBarIDs.contains(status.id) },
                                                  set: { model.setInMenuBar(status.account, $0) }),
                               hide: { model.setHidden(status.account, true) },
                               reload: { model.refresh(status.account) })
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No accounts found").font(.headline)
            Text("AI Usage looks for Claude Code, Codex, OpenCode and Pi logins on this Mac (read-only). You can also sign in or add API keys yourself.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add account…", action: actions.openAccounts).padding(.top, 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(title: "Refresh now", shortcut: "R") { model.refresh() }
                .keyboardShortcut("r")
            MenuRow(title: settings.showRemaining ? "Show used" : "Show remaining", shortcut: "I") { settings.showRemaining.toggle() }
                .keyboardShortcut("i")
            MenuRow(title: settings.refreshGuide ? "Hide usage refresh guide" : "Show usage refresh guide", shortcut: "G") { settings.refreshGuide.toggle() }
                .keyboardShortcut("g")
            MenuRow(title: "Accounts…", shortcut: nil, action: actions.openAccounts)
            MenuRow(title: "Settings…", shortcut: ",", action: actions.openSettings)
                .keyboardShortcut(",")
            MenuRow(title: "Quit AI Usage", shortcut: "Q", secondary: true, action: actions.quit)
                .keyboardShortcut("q")
        }
    }
}

struct MenuRow: View {
    let title: String
    let shortcut: String?
    var secondary = false
    let action: () -> Void
    @StateObject private var hover = Flag()
    private var hovering: Bool { hover.value }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text("⌘\(shortcut)").foregroundStyle(.tertiary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? Color.white : secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
    }
}

struct AccountSection: View {
    let status: AccountStatus
    let remaining: Bool
    let refreshGuide: Bool
    let refreshing: Bool
    @Binding var inMenuBar: Bool
    let hide: () -> Void
    let reload: () -> Void

    private var state: UsageState? { status.analysis?.state }
    private var tint: Color { Color(nsColor: Theme.color(for: state)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ProviderMark(provider: status.account.provider, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(status.account.provider.displayName).font(.system(size: 14, weight: .semibold))
                        if let badge = state?.badge { StateBadge(text: badge, color: tint) }
                        if let plan = Format.planLabel(status.snapshot?.plan) {
                            Text(plan).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(status.account.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(status.account.sourceDescription).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                // Spinner while loading, otherwise the time of the last update, in the same spot.
                ZStack(alignment: .trailing) {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        RefreshButton(updated: status.snapshot?.observedAt, next: status.nextRefresh, action: reload)
                    }
                }
                .frame(minWidth: 20, alignment: .trailing)
            }
            if let snap = status.snapshot {
                ForEach(Array((snap.windows + snap.extraWindows).enumerated()), id: \.offset) { _, w in
                    WindowRow(window: w, tint: tint, remaining: remaining, refreshGuide: refreshGuide)
                }
                if let balance = snap.balance {
                    HStack(spacing: 8) {
                        Text("Balance").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Text(balance.formatted).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                    }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(status.error ?? status.analysis?.message ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(status.error != nil ? Color(nsColor: Theme.alert) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Toggle("Menu bar", isOn: $inMenuBar)
                    .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
                    .help("Show this account in the menu bar title")
                Button("Hide", action: hide)
                    .buttonStyle(.link).controlSize(.small).font(.system(size: 11))
                    .help("Hide from the list (bring it back in Accounts…)")
            }
        }
    }
}

/// "updated 14:32 ⟳": click to update this account now.
struct RefreshButton: View {
    let updated: Date?
    let next: Date?
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let updated { Text("updated \(Format.clock(updated))").monospacedDigit() }
                Image(systemName: "arrow.clockwise")
            }
            .font(.system(size: 11))
            .foregroundStyle(hover.value ? Color.primary : Color.secondary.opacity(0.7))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hover.value ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .help(next.map { "Update now · next automatic update at \(Format.clock($0))" } ?? "Update now")
    }
}

struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let tint: Color
    let remaining: Bool
    let refreshGuide: Bool

    var body: some View {
        let shown = window.display(remaining: remaining)
        HStack(spacing: 8) {
            Text(window.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Meter(value: shown.percent, time: refreshGuide ? shown.time : nil, tint: tint)
                .help(timeHelp(shown.time))
            Text(Format.percent(shown.percent)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint).frame(width: 34, alignment: .trailing)
            Text(Format.countdown(window.resetsAt)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
                .help(Format.reset(window.resetsAt))
        }
    }

    private func timeHelp(_ time: Double?) -> String {
        guard let time else { return "" }
        return "\(Int((time * 100).rounded()))% of the window's time \(remaining ? "left" : "elapsed")"
    }
}

/// Usage bar with the usage refresh guide: an I-beam cursor where the window's time has got to.
/// Usage reaching past the cursor means quota is being used faster than the window elapses.
struct Meter: View {
    let value: Double
    var time: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22)).frame(height: 6)
                if value > 0 {
                    Capsule().fill(tint).frame(width: max(6, w * min(value, 100) / 100), height: 6)
                }
                if let time {
                    IBeam().stroke(Color.primary.opacity(0.45), lineWidth: 1)
                        .frame(width: 4, height: 9).offset(x: w * min(max(time, 0), 1) - 2)
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 10)
    }
}

/// An "I": vertical stem with short serifs at both ends.
struct IBeam: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}
