import AppKit
import ApplicationServices
import os

/// Observes the native macOS Dock's accessibility tree for item add/remove and
/// fires `onChange` (no polling). Re-registers when the Dock relaunches. Shared
/// by every tracker that mirrors a class of native Dock item
/// (`OrphanedWindowTracker`, `DockHandoffTracker`); each supplies its own
/// coalescing and item filtering.
///
/// Lifecycle (`start`/`stop`) is driven on the main run loop; the accessibility
/// read helpers are thread-safe and may be called from a tracker's work queue.
final class DockAXObserver: @unchecked Sendable {
    /// Fired on the main run loop whenever a Dock item is created or destroyed.
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var dockApp: AXUIElement?
    private var workspaceObservers: [NSObjectProtocol] = []
    // Written on main (register), read off the work queue (item reads).
    private let pid = OSAllocatedUnfairLock<pid_t>(initialState: 0)

    /// The Dock's current process id, or 0 when it isn't running.
    var dockPID: pid_t { pid.withLock { $0 } }

    func start() {
        registerDockObserver()
        startWorkspaceObservers()
    }

    func stop() {
        tearDownDockObserver()
        stopWorkspaceObservers()
    }

    // MARK: Observer

    private func registerDockObserver() {
        tearDownDockObserver()
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return }
        let dockPID = dock.processIdentifier
        pid.withLock { $0 = dockPID }
        let app = AXUIElementCreateApplication(dockPID)
        dockApp = app

        var newObserver: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(dockPID, Self.observerCallback, &newObserver) == .success,
              let newObserver else { return }
        observer = newObserver
        for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(newObserver, app, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
    }

    private func tearDownDockObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        if let dockApp {
            for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(observer, dockApp, notification as CFString)
            }
        }
        self.observer = nil
        dockApp = nil
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<DockAXObserver>.fromOpaque(refcon).takeUnretainedValue()
        observer.onChange?()
    }

    private func startWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let relaunch: (Notification) -> Void = { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock", let self else { return }
            self.registerDockObserver()
            self.onChange?()
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: relaunch))
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: relaunch))
    }

    private func stopWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    // MARK: Accessibility reads (thread-safe)

    /// The Dock's top-level `AXList` element that holds the dock items, or `nil`.
    func dockItemList() -> AXUIElement? {
        let resolvedPID = dockPID == 0 ? currentDockPID() : dockPID
        guard resolvedPID != 0 else { return nil }
        let app = AXUIElementCreateApplication(resolvedPID)
        guard let children = Self.axCopy(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        return children.first { Self.axString($0, kAXRoleAttribute) == (kAXListRole as String) }
    }

    private func currentDockPID() -> pid_t {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier ?? 0
    }

    static func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axCopy(element, attribute) as? String
    }
}
