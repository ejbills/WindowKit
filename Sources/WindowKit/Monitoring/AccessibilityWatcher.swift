import ApplicationServices
import Cocoa
import Combine

private let axObserverWorkQueue = DispatchQueue(label: "com.windowkit.axObserverWork", qos: .userInitiated)
private var pendingNotifications: [String: DispatchWorkItem] = [:]
private let notificationDebounceInterval: TimeInterval = 0.1

public enum AccessibilityEvent {
    case windowCreated(AXUIElement)
    case windowDestroyed(AXUIElement)
    case windowMinimized(AXUIElement)
    case windowRestored(AXUIElement)
    case applicationHidden
    case applicationRevealed
    case windowFocused(AXUIElement)
    case windowResized(AXUIElement)
    case windowMoved(AXUIElement)
    case titleChanged(AXUIElement)
    case mainWindowChanged(AXUIElement)
}

public final class AccessibilityWatcher {
    public let targetPID: pid_t
    public let events: AnyPublisher<AccessibilityEvent, Never>

    private let eventSubject = PassthroughSubject<AccessibilityEvent, Never>()
    private var observer: AXObserver?
    private let appElement: AXUIElement

    private static let notificationNames: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowResizedNotification,
        kAXWindowMovedNotification,
        kAXTitleChangedNotification,
        kAXMainWindowChangedNotification,
    ]

    public init?(pid: pid_t) {
        self.targetPID = pid
        self.appElement = AXUIElement.application(pid: pid)
        self.events = eventSubject.eraseToAnyPublisher()

        guard setupObserver() else {
            return nil
        }
    }

    deinit {
        stopWatching()
    }

    public func stopWatching() {
        guard let observer = observer else { return }

        for notification in Self.notificationNames {
            AXObserverRemoveNotification(observer, appElement, notification as CFString)
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        self.observer = nil

        let pid = targetPID
        axObserverWorkQueue.async {
            for (key, workItem) in pendingNotifications where key.hasPrefix("\(pid)-") {
                workItem.cancel()
                pendingNotifications.removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    public func reset() -> Bool {
        stopWatching()
        return setupObserver()
    }

    private func setupObserver() -> Bool {
        var newObserver: AXObserver?

        let callback: AXObserverCallback = { _, element, notification, userData in
            guard let userData = userData else { return }
            let watcher = Unmanaged<AccessibilityWatcher>.fromOpaque(userData).takeUnretainedValue()
            watcher.handleNotification(element: element, name: notification as String)
        }

        let result = AXObserverCreate(targetPID, callback, &newObserver)
        guard result == .success, let observer = newObserver else {
            return false
        }

        self.observer = observer

        let userData = Unmanaged.passUnretained(self).toOpaque()
        var registeredNotifications = [String]()
        for notification in Self.notificationNames {
            let result = AXObserverAddNotification(
                observer,
                appElement,
                notification as CFString,
                userData
            )

            if result == .success || result == .notificationAlreadyRegistered {
                registeredNotifications.append(notification)
            }
        }

        let requiredNotifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
        ]
        let missingRequired = requiredNotifications.filter { !registeredNotifications.contains($0) }
        guard missingRequired.isEmpty else {
            for notification in registeredNotifications {
                AXObserverRemoveNotification(observer, appElement, notification as CFString)
            }
            self.observer = nil
            return false
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        return true
    }

    private func handleNotification(element: AXUIElement, name: String) {
        let key = "\(targetPID)-\(name)"

        axObserverWorkQueue.async { [weak self] in
            guard let self else { return }

            pendingNotifications[key]?.cancel()

            let event: AccessibilityEvent? = switch name {
            case kAXWindowCreatedNotification:
                .windowCreated(element)
            case kAXUIElementDestroyedNotification:
                .windowDestroyed(element)
            case kAXWindowMiniaturizedNotification:
                .windowMinimized(element)
            case kAXWindowDeminiaturizedNotification:
                .windowRestored(element)
            case kAXApplicationHiddenNotification:
                .applicationHidden
            case kAXApplicationShownNotification:
                .applicationRevealed
            case kAXFocusedWindowChangedNotification:
                .windowFocused(element)
            case kAXWindowResizedNotification:
                .windowResized(element)
            case kAXWindowMovedNotification:
                .windowMoved(element)
            case kAXTitleChangedNotification:
                .titleChanged(element)
            case kAXMainWindowChangedNotification:
                .mainWindowChanged(element)
            default:
                nil
            }

            guard let event else { return }

            let workItem = DispatchWorkItem { [weak self] in
                pendingNotifications.removeValue(forKey: key)
                self?.eventSubject.send(event)
            }

            pendingNotifications[key] = workItem
            axObserverWorkQueue.asyncAfter(deadline: .now() + notificationDebounceInterval, execute: workItem)
        }
    }
}

public final class AccessibilityWatcherManager {
    private var watchers: [pid_t: AccessibilityWatcher] = [:]
    private var subscriptions: [pid_t: AnyCancellable] = [:]
    private let eventSubject = PassthroughSubject<(pid_t, AccessibilityEvent), Never>()
    private let lock = NSLock()

    public var events: AnyPublisher<(pid_t, AccessibilityEvent), Never> {
        eventSubject.eraseToAnyPublisher()
    }

    public init() {}

    @discardableResult
    public func watch(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard watchers[pid] == nil else { return true }

        guard let watcher = AccessibilityWatcher(pid: pid) else {
            return false
        }

        watchers[pid] = watcher

        subscriptions[pid] = watcher.events
            .sink { [weak self] event in
                self?.eventSubject.send((pid, event))
            }

        return true
    }

    public func unwatch(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        subscriptions.removeValue(forKey: pid)?.cancel()
        watchers.removeValue(forKey: pid)?.stopWatching()
    }

    public func unwatchAll() {
        lock.lock()
        defer { lock.unlock() }

        for (_, cancellable) in subscriptions {
            cancellable.cancel()
        }
        for (_, watcher) in watchers {
            watcher.stopWatching()
        }
        subscriptions.removeAll()
        watchers.removeAll()
    }

    public func resetAll() {
        lock.lock()
        let pids = Array(watchers.keys)
        lock.unlock()

        for pid in pids {
            lock.lock()
            let watcher = watchers[pid]
            lock.unlock()

            if let watcher, !watcher.reset() {
                unwatch(pid: pid)
            }
        }
    }

    public func isWatching(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watchers[pid] != nil
    }
}
