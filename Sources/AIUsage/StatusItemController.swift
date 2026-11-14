import AIUsageCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let settings: AppSettings
    private let clock: Clock
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var eventMonitor: Any?
    /// Invisible window the popover is anchored to, so it stays put when the menu bar item resizes.
    private var anchorWindow: NSWindow?

    init(model: AppModel, settings: AppSettings, clock: Clock, actions: PanelActions) {
        self.model = model
        self.settings = settings
        self.clock = clock
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model, settings: settings, clock: clock, actions: actions))

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }

        Publishers.CombineLatest3(model.$statuses.map { _ in () }, model.$notInMenuBarIDs.map { _ in () },
                                  settings.$showAccountNames.map { _ in () })
            .combineLatest(settings.$titleMode, settings.$displayStyle, settings.$showRemaining)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        // Bars, percent left and the refresh guide depend on the time, so redraw on every clock tick
        // (each minute, after wake, on clock changes) even when no data changed.
        clock.$now.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.render() } }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        render()
    }

    @objc private func screensChanged() { render() }

    func render() {
        guard let button = item.button else { return }
        let statuses = model.statuses.filter { !model.notInMenuBarIDs.contains($0.id) }
        let configuration = settings.displayStyle
        var mode = settings.titleMode
        let remaining = settings.showRemaining
        let now = clock.now
        let all = TitleRenderer.segments(for: statuses, remaining: remaining, now: now)

        if mode == .auto {
            let budget = TitleRenderer.menuBarBudget()
            let fullWidth = TitleRenderer.image(for: all, configuration: configuration).size.width
            let urgentSegment = TitleRenderer.mostUrgent(statuses).flatMap { urgent in
                TitleRenderer.segments(for: [urgent], remaining: remaining, now: now).first
            }
            let singleWidth = urgentSegment.map { TitleRenderer.width(of: $0, configuration: configuration) } ?? 0
            mode = all.isEmpty ? .icon : fullWidth <= budget ? .full : budget >= singleWidth ? .single : .icon
        }

        let image: NSImage
        switch mode {
        case .full where !all.isEmpty:
            image = TitleRenderer.image(for: all, configuration: configuration)
        case .single, .full:
            if let urgent = TitleRenderer.mostUrgent(statuses) {
                image = TitleRenderer.image(for: TitleRenderer.segments(for: [urgent], remaining: remaining, now: now), configuration: configuration)
            } else {
                image = TitleRenderer.iconImage(worst: nil)
            }
        default:
            image = TitleRenderer.iconImage(worst: TitleRenderer.mostUrgent(statuses)?.analysis?.state)
        }
        button.image = image
        button.toolTip = tooltip(statuses, remaining: remaining, now: now)
    }

    private func tooltip(_ statuses: [AccountStatus], remaining: Bool, now: Date) -> String {
        guard !statuses.isEmpty else { return "AI Usage — no accounts yet" }
        return statuses.map { s in
            let windows = (s.snapshot?.windows ?? []).map {
                "\($0.label) \(Format.percent($0.display(remaining: remaining, now: now).percent))\(remaining ? " left" : "")"
            }.joined(separator: ", ")
            let value = s.snapshot?.balance?.formatted ?? windows
            let name = settings.showAccountNames ? " · \(s.account.label)" : ""
            return "\(s.account.provider.displayName)\(name): \(s.error == nil ? value : "error")"
        }.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else if let button = item.button, let buttonWindow = button.window {
            // Redraw the dropdown (and title) against the current time every time it opens.
            clock.tick()
            NSApp.activate(ignoringOtherApps: true)
            // The popover follows its anchor view, and the status item changes width (e.g. when an
            // account is toggled in the menu bar). Anchor it to a fixed copy of the button's frame.
            let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            let anchor = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            anchor.isOpaque = false
            anchor.backgroundColor = .clear
            anchor.hasShadow = false
            anchor.ignoresMouseEvents = true
            anchor.level = buttonWindow.level
            anchor.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            anchor.orderFrontRegardless()
            anchorWindow = anchor
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        cleanUpAfterPopover()
    }

    func popoverDidClose(_ notification: Notification) { cleanUpAfterPopover() }

    private func cleanUpAfterPopover() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }
}
