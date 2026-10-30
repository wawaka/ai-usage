import AIUsageCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var eventMonitor: Any?

    init(model: AppModel, settings: AppSettings, actions: PanelActions) {
        self.model = model
        self.settings = settings
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model, settings: settings, actions: actions))

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        model.$statuses.combineLatest(settings.$titleMode, settings.$titleStyle, settings.$showRemaining)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        render()
    }

    @objc private func screensChanged() { render() }

    func render() {
        guard let button = item.button else { return }
        let statuses = model.statuses
        let style = settings.titleStyle
        var mode = settings.titleMode
        let remaining = settings.showRemaining
        let all = TitleRenderer.segments(for: statuses, remaining: remaining)

        if mode == .auto {
            let budget = TitleRenderer.menuBarBudget()
            let fullWidth = TitleRenderer.image(for: all, style: style).size.width
            mode = all.isEmpty ? .icon : fullWidth <= budget ? .full : budget >= 90 ? .single : .icon
        }

        let image: NSImage
        switch mode {
        case .full where !all.isEmpty:
            image = TitleRenderer.image(for: all, style: style)
        case .single, .full:
            if let urgent = TitleRenderer.mostUrgent(statuses) {
                image = TitleRenderer.image(for: TitleRenderer.segments(for: [urgent], remaining: remaining), style: style)
            } else {
                image = TitleRenderer.iconImage(worst: nil)
            }
        default:
            image = TitleRenderer.iconImage(worst: TitleRenderer.mostUrgent(statuses)?.analysis?.state)
        }
        button.image = image
        button.toolTip = tooltip(statuses, remaining: remaining)
    }

    private func tooltip(_ statuses: [AccountStatus], remaining: Bool) -> String {
        guard !statuses.isEmpty else { return "AI Usage — no accounts yet" }
        return statuses.map { s in
            let windows = (s.snapshot?.windows ?? []).map {
                "\($0.label) \(Format.percent($0.display(remaining: remaining).percent))\(remaining ? " left" : "")"
            }.joined(separator: ", ")
            let value = s.snapshot?.balance?.formatted ?? windows
            return "\(s.account.provider.displayName) · \(s.account.label): \(s.error == nil ? value : "error")"
        }.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else if let button = item.button {
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }
}
