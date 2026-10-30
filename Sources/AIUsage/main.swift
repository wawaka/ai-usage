import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var model: AppModel!
    private var statusController: StatusItemController!
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = AppSettings()
        model = AppModel(settings: settings)
        let actions = PanelActions(
            openAccounts: { [weak self] in self?.showAccounts() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { NSApp.terminate(nil) })
        statusController = StatusItemController(model: model, settings: settings, actions: actions)
    }

    private func showAccounts() {
        show("accounts", title: "AI Usage — Accounts") { AccountsView(model: self.model) }
    }

    private func showSettings() {
        show("settings", title: "AI Usage — Settings") { SettingsView(settings: self.settings) }
    }

    private func show<V: View>(_ key: String, title: String, content: () -> V) {
        statusController.closePopover()
        let window: NSWindow
        if let existing = windows[key] {
            window = existing
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            windows[key] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon (also set via LSUIElement in Info.plist).
app.setActivationPolicy(.accessory)
app.run()
