import AppKit
import Combine

/// The time the UI draws relative values against (time left, pace cursor, percent left, data age).
/// One clock drives both the menu bar title and the dropdown, so they always agree.
///
/// It ticks on every whole minute, and also right away when:
/// - the Mac or its screens wake, or the user session becomes active again (the minute timer was
///   suspended, possibly for hours);
/// - the system clock or time zone changes, or the day rolls over;
/// - the dropdown opens (`tick()` from `StatusItemController`).
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        arm()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name)
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(.default, name)
        }
    }

    /// Redraws everything that depends on the time now.
    func tick() { now = Date() }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
                // Line the timer up with whole minutes again after a sleep or a clock change.
                self?.arm()
            }
        }
    }

    /// Fires on each whole minute. `.common` mode keeps it firing while a menu or control is tracking
    /// the mouse, which a plain `scheduledTimer` (default mode only) does not.
    private func arm() {
        timer?.invalidate()
        let minute = 60.0
        let next = Date(timeIntervalSinceReferenceDate:
            (Date().timeIntervalSinceReferenceDate / minute).rounded(.down) * minute + minute)
        let timer = Timer(fire: next, interval: minute, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
