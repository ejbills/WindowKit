import AppKit
import ApplicationServices
import os

/// Observes the native macOS Dock's accessibility tree for item add/remove and
/// tells its subscribers (no polling). Re-registers when the Dock process relaunches,
/// detected by watching `NSWorkspace.runningApplications` for a Dock pid change
/// (WindowKit's `ProcessEvent` stream can't drive this: it only emits launches
/// for `.regular` apps, and the Dock is a UIElement process). One instance is
/// shared by every tracker that mirrors a class of native Dock item
/// (`OrphanedWindowTracker`, `DockHandoffTracker`, `MinimizeTransitionTracker`);
/// each supplies its own coalescing and item filtering.
///
/// Subscriptions are driven on the main run loop; the accessibility read helpers
/// are thread-safe and may be called from a tracker's work queue.
final class DockAXObserver: @unchecked Sendable {
    private struct Subscriber {
        let onChange: (() -> Void)?
        let onCreated: ((AXUIElement) -> Void)?
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private let runLoopMode: CFRunLoopMode
    private var observer: AXObserver?
    private var dockApp: AXUIElement?
    private var runningAppsObservation: NSKeyValueObservation?
    // Written on main (register), read off the work queue (item reads).
    private let pid = OSAllocatedUnfairLock<pid_t>(initialState: 0)
    // Pid the AX observer is successfully bound to (0 when unbound). Main only.
    private var boundPID: pid_t = 0
    private var rebindRetriesRemaining = 0

    /// The Dock's current process id, or 0 when it isn't running.
    var dockPID: pid_t { pid.withLock { $0 } }

    /// `runLoopMode` `.commonModes` keeps notifications flowing while the main thread
    /// is in a tracking mode (menus, drags, scrolling).
    init(runLoopMode: CFRunLoopMode = .defaultMode) {
        self.runLoopMode = runLoopMode
    }

    /// Calls `onChange` on the main run loop whenever a Dock item is created or destroyed (and after the Dock
    /// relaunches), and `onCreated` with each new item's element, until `unsubscribe`. The first subscriber
    /// starts the observer.
    func subscribe(_ subscriber: AnyObject, onChange: (() -> Void)? = nil, onCreated: ((AXUIElement) -> Void)? = nil) {
        let wasIdle = subscribers.isEmpty
        subscribers[ObjectIdentifier(subscriber)] = Subscriber(onChange: onChange, onCreated: onCreated)
        if wasIdle { start() }
    }

    /// Stops calling `subscriber`; the last one to leave stops the observer.
    func unsubscribe(_ subscriber: AnyObject) {
        guard subscribers.removeValue(forKey: ObjectIdentifier(subscriber)) != nil, subscribers.isEmpty else { return }
        stop()
    }

    private func start() {
        registerDockObserver()
        observeDockPIDChanges()
    }

    private func stop() {
        tearDownDockObserver()
        runningAppsObservation?.invalidate()
        runningAppsObservation = nil
    }

    private func notifyChange() {
        for subscriber in Array(subscribers.values) {
            subscriber.onChange?()
        }
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
        var registered = true
        for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
            if AXObserverAddNotification(newObserver, app, notification as CFString, context) != .success {
                registered = false
            }
        }
        guard registered else {
            tearDownDockObserver()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), runLoopMode)
        boundPID = dockPID
    }

    private func tearDownDockObserver() {
        boundPID = 0
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), runLoopMode)
        if let dockApp {
            for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(observer, dockApp, notification as CFString)
            }
        }
        self.observer = nil
        dockApp = nil
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<DockAXObserver>.fromOpaque(refcon).takeUnretainedValue()
        if notification as String == kAXCreatedNotification {
            for subscriber in Array(observer.subscribers.values) {
                subscriber.onCreated?(element)
            }
        }
        observer.notifyChange()
    }

    /// The AX observer binds to a specific pid, so a Dock relaunch would leave it
    /// attached to a dead process. Watches workspace membership and rebinds when
    /// the Dock's pid changes, retrying briefly when the fresh Dock's AX server
    /// isn't accepting registrations yet.
    private func observeDockPIDChanges() {
        runningAppsObservation?.invalidate()
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.rebindRetriesRemaining = 5
                self?.rebindIfDockPIDChanged()
            }
        }
        rebindRetriesRemaining = 5
        rebindIfDockPIDChanged()
    }

    private func rebindIfDockPIDChanged() {
        guard runningAppsObservation != nil else { return }
        if boundPID != 0, kill(boundPID, 0) == 0 { return }
        let current = currentDockPID()
        guard current != 0, current != boundPID else { return }
        registerDockObserver()
        if boundPID == current {
            notifyChange()
        } else if rebindRetriesRemaining > 0 {
            rebindRetriesRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.rebindIfDockPIDChanged()
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
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
    }

    static func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        axCopy(element, attribute) as? String
    }
}
