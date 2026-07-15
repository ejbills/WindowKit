import AppKit
import ApplicationServices
import Combine
import os

/// Observes the native macOS Dock's accessibility tree for item add/remove and
/// fires `onChange` (no polling). Re-registers when the Dock process relaunches,
/// driven off WindowKit's existing `ProcessEvent` stream rather than its own
/// workspace observers. Shared by every tracker that mirrors a class of native
/// Dock item (`OrphanedWindowTracker`, `DockHandoffTracker`); each supplies its
/// own coalescing and item filtering.
///
/// Lifecycle (`start`/`stop`) is driven on the main run loop; the accessibility
/// read helpers are thread-safe and may be called from a tracker's work queue.
final class DockAXObserver: @unchecked Sendable {
    /// Fired on the main run loop whenever a Dock item is created or destroyed.
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var dockApp: AXUIElement?
    private var lifecycleCancellable: AnyCancellable?
    // Written on main (register), read off the work queue (item reads).
    private let pid = OSAllocatedUnfairLock<pid_t>(initialState: 0)

    /// The Dock's current process id, or 0 when it isn't running.
    var dockPID: pid_t { pid.withLock { $0 } }

    /// - Parameter processEvents: WindowKit's app-lifecycle stream, used to
    ///   rebind the AX observer when the Dock relaunches under a new pid.
    func start(processEvents: AnyPublisher<ProcessEvent, Never>?) {
        registerDockObserver()
        observeDockRelaunch(processEvents)
    }

    func stop() {
        tearDownDockObserver()
        lifecycleCancellable = nil
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

    /// The AX observer binds to a specific pid, so a Dock relaunch would leave it
    /// attached to a dead process. Rebind on the Dock's launch/terminate events
    /// from the shared `ProcessEvent` stream (delivered on the main run loop).
    private func observeDockRelaunch(_ processEvents: AnyPublisher<ProcessEvent, Never>?) {
        lifecycleCancellable = processEvents?.sink { [weak self] event in
            guard let self else { return }
            switch event {
            case let .applicationLaunched(app) where app.bundleIdentifier == "com.apple.dock":
                self.registerDockObserver()
                self.onChange?()
            case let .applicationTerminated(pid) where pid == self.dockPID:
                self.tearDownDockObserver()
            default:
                break
            }
        }
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
