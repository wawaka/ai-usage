import AIUsageCore
import SwiftUI

struct PanelActions {
    var openAccounts: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// The dropdown card, modelled on coding-usage-bar's: one section per account with a state badge,
/// the binding percentage, 5h/7d meters with reset times, the pacing hint and data age.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
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
                AccountSection(status: status)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AI Usage").font(.system(size: 14, weight: .bold))
            Text(settings.profile.rawValue.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let last = model.lastRefresh {
                Text(last, format: .dateTime.month(.defaultDigits).day().hour().minute())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
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

    private var state: BurnState? { status.analysis?.state }
    private var tint: Color { Color(nsColor: Theme.color(for: state)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ProviderMark(provider: status.account.provider, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(status.account.provider.displayName).font(.system(size: 14, weight: .semibold))
                        if let state { StateBadge(text: state.badge, color: tint) }
                        if let plan = Format.planLabel(status.snapshot?.plan) {
                            Text(plan).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text(status.account.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                headline
            }
            if let snap = status.snapshot {
                ForEach(Array((snap.windows + snap.extraWindows).enumerated()), id: \.offset) { _, w in
                    WindowRow(window: w, tint: tint)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(status.error ?? status.analysis?.message ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(status.error != nil ? Color(nsColor: Theme.alert) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let at = status.snapshot?.observedAt {
                    Text("updated \(Format.clock(at))").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .help(status.account.sourceDescription)
    }

    @ViewBuilder private var headline: some View {
        if let balance = status.snapshot?.balance {
            Text(balance.formatted).font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        } else if let pct = Format.bindingPercent(status.snapshot) {
            Text(Format.percent(pct)).font(.system(size: 20, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Meter(value: window.usedPercent, tint: tint)
            Text(Format.percent(window.usedPercent)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint).frame(width: 34, alignment: .trailing)
            Text(Format.reset(window.resetsAt)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
                .help(Format.countdown(window.resetsAt))
        }
    }
}

struct Meter: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                if value > 0 {
                    Capsule().fill(tint).frame(width: max(6, geo.size.width * min(value, 100) / 100))
                }
            }
        }
        .frame(height: 6)
    }
}
