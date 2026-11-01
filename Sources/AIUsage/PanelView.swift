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
                AccountSection(status: status, remaining: settings.showRemaining,
                               showName: settings.showAccountNames,
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
            MenuRow(title: "Refresh all now", shortcut: "R") { model.refresh() }
                .keyboardShortcut("r")
            ToggleRow(title: "Show remaining", shortcut: "I", isOn: $settings.showRemaining)
            ToggleRow(title: "Account names", shortcut: "N", isOn: $settings.showAccountNames)
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
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

/// A setting in the dropdown: label, shortcut hint and a switch. Clicking anywhere on the row
/// (or pressing ⌘<shortcut>) flips it.
struct ToggleRow: View {
    let title: String
    let shortcut: Character
    @Binding var isOn: Bool
    @StateObject private var hover = Flag()

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("⌘\(String(shortcut))").foregroundStyle(.tertiary)
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover.value ? 0.06 : 0)))
        .onTapGesture { isOn.toggle() }
        .onHover { hover.value = $0 }
        // Invisible button that carries the keyboard shortcut.
        .background(Button(title) { isOn.toggle() }.keyboardShortcut(KeyEquivalent(shortcut)).opacity(0).allowsHitTesting(false))
    }
}

struct AccountSection: View {
    let status: AccountStatus
    let remaining: Bool
    let showName: Bool
    let refreshing: Bool
    @Binding var inMenuBar: Bool
    let hide: () -> Void
    let reload: () -> Void

    private var state: UsageState? { status.analysis?.state }
    private var tint: Color { Color(nsColor: Theme.color(for: state)) }

    private var message: String? {
        let text = status.error ?? status.analysis?.message
        return text?.isEmpty == false ? text : nil
    }

    private var windows: [UsageWindow] { (status.snapshot?.windows ?? []) + (status.snapshot?.extraWindows ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                ProviderMark(provider: status.account.provider, size: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 0) {
                    // Title on the left; per-account controls share its line on the right.
                    HStack(alignment: .center, spacing: 6) {
                        Text(status.account.provider.displayName).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).layoutPriority(1)
                        if let badge = state?.badge { StateBadge(text: badge, color: tint) }
                        if let plan = Format.planLabel(status.snapshot?.plan) {
                            StateBadge(text: plan, color: .secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        controls
                    }
                    if showName {
                        Text(status.account.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Text(status.account.sourceDescription).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            let labelWidth: CGFloat = windows.contains { $0.label.count > 3 } ? 58 : 20
            ForEach(Array(windows.enumerated()), id: \.offset) { _, w in
                WindowRow(window: w, tint: tint, remaining: remaining, labelWidth: labelWidth)
            }
            if let balance = status.snapshot?.balance {
                HStack(spacing: 6) {
                    Text("Balance").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(balance.formatted).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(status.error != nil ? Color(nsColor: Theme.alert) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Menu bar checkbox, Hide, and the data age / refresh button (a spinner while loading).
    private var controls: some View {
        HStack(spacing: 8) {
            Toggle("Menu bar", isOn: $inMenuBar)
                .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11)).fixedSize()
                .help("Show this account in the menu bar title")
            Button("Hide", action: hide)
                .buttonStyle(.link).controlSize(.small).font(.system(size: 11)).fixedSize()
                .help("Hide from the list (bring it back in Accounts…)")
            ZStack(alignment: .trailing) {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    RefreshButton(updated: status.snapshot?.observedAt, next: status.nextRefresh, action: reload)
                }
            }
            .frame(minWidth: 20, alignment: .trailing)
            .fixedSize()
        }
    }
}

/// "5m ago ⟳": age of the data; click to update this account now.
struct RefreshButton: View {
    let updated: Date?
    let next: Date?
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let updated {
                    // Re-rendered every 30 s so the age stays current while the dropdown is open.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Format.ago(updated, now: context.date)).monospacedDigit()
                    }
                }
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
        .help([updated.map { "Updated at \(Format.clock($0))" }, "click to update now",
               next.map { "next automatic update at \(Format.clock($0))" }].compactMap { $0 }.joined(separator: " · "))
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
    /// Same for every row of an account, so their bars line up.
    var labelWidth: CGFloat = 20

    var body: some View {
        let shown = window.display(remaining: remaining)
        let idle = window.isUntouched
        let color = idle ? Color.secondary : tint
        // The bar takes all the width between the label and the percent + time-left columns.
        // An untouched window is a plain grey bar: no cursor, no countdown (its clock hasn't started).
        HStack(spacing: 6) {
            Text(window.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: labelWidth, alignment: .leading)
            Meter(value: shown.percent, time: shown.time, tint: idle ? Color.secondary.opacity(0.5) : tint)
                .help(idle ? "Not used yet. The window starts with the first request." : timeHelp(shown.time))
            Text(Format.percent(shown.percent)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color).frame(width: 34, alignment: .trailing)
            Text(idle ? "" : Format.countdown(window.resetsAt)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 48, alignment: .trailing)
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
