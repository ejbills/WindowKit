import AppKit
import ApplicationServices
import Combine
import os

// MARK: - Public model

/// The item currently highlighted in the macOS system Cmd+Tab switcher.
public struct AppSwitcherSelection: Equatable, Sendable {
    /// The pid of the app the highlighted item is assigned to (`0` if it could not be resolved).
    public let ownerPID: pid_t
    /// Resolved bundle identifier of the selected app (`kAXURLAttribute` → `Bundle`).
    public let bundleIdentifier: String?
    /// AX title of the selected item.
    public let title: String?
    /// The selected item's rect, in AX/Quartz coordinates (top-left origin, flipped vs AppKit).
    public let frame: CGRect
}

/// Lifecycle of the system Cmd+Tab switcher, as observed from the Dock's AX tree.
public enum AppSwitcherEvent: Sendable {
    case appeared(AppSwitcherSelection)
    case selectionChanged(AppSwitcherSelection)
    case dismissed
}

// MARK: - Observer

/// Observes the macOS Cmd+Tab process switcher by watching the Dock process's
/// accessibility tree (the `AXProcessSwitcherList` element). Pure observation — no
/// event tap, no keybind handling. Modeled on `OrphanedWindowTracker`.
final class AppSwitcherObserver: @unchecked Sendable {
    private static let switcherSubrole = "AXProcessSwitcherList"
    /// Fail fast instead of waiting out the default ~6s AX messaging timeout.
    private static let messagingTimeout: Float = 0.25

    var selectionPublisher: AnyPublisher<AppSwitcherSelection?, Never> { selectionSubject.eraseToAnyPublisher() }
    var eventPublisher: AnyPublisher<AppSwitcherEvent, Never> { eventSubject.eraseToAnyPublisher() }
    private let selectionSubject = CurrentValueSubject<AppSwitcherSelection?, Never>(nil)
    private let eventSubject = PassthroughSubject<AppSwitcherEvent, Never>()

    private let queue = DispatchQueue(label: "com.windowkit.appSwitcher", qos: .userInitiated)
    private let isActive = OSAllocatedUnfairLock(initialState: false)

    private static let probeInterval: TimeInterval = 0.1
    private static let probeTickLimit = 20
    private static let sessionPollInterval: TimeInterval = 0.025

    // Touched only on `queue`.
    private var scanScheduled = false
    private var currentSelection: AppSwitcherSelection?
    private var probeTicksRemaining = 0
    private var sessionPolling = false
    /// Consecutive session polls the Dock failed to answer (throwing reads).
    /// ~275ms each (poll interval + messaging timeout), so 36 ≈ 10s wedged.
    private static let unknownReadLimit = 36
    private var unknownReads = 0

    /// Written by `scan()` on `queue`, read by `tearDownDockObserver()` on
    /// main — an unsynchronized strong CF reference re-assigned cross-thread
    /// can over-release. All access goes through this lock.
    private let attachedList = OSAllocatedUnfairLock<AXUIElement?>(uncheckedState: nil)

    // Dock AX observer. Mutated on main (start/stop/re-register).
    private var observer: AXObserver?
    private var dockApp: AXUIElement?
    private var dockPID: pid_t = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {}
    deinit { stop() }

    // MARK: Lifecycle

    func start() {
        guard !isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = true }
        Logger.info("Starting Cmd+Tab process switcher observation")
        registerDockObserver()
        startWorkspaceObservers()
        scheduleScan()
    }

    func stop() {
        guard isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = false }
        Logger.info("Stopping Cmd+Tab process switcher observation")
        tearDownDockObserver()
        stopWorkspaceObservers()
        queue.async { [weak self] in
            guard let self else { return }
            self.currentSelection = nil
            self.scanScheduled = false
            self.probeTicksRemaining = 0
            self.sessionPolling = false
            self.unknownReads = 0
        }
        if selectionSubject.value != nil { selectionSubject.send(nil) }
    }

    // MARK: Discovery probe

    func probe() {
        queue.async { [weak self] in
            guard let self, self.isActive.withLock({ $0 }) else { return }
            let alreadyProbing = self.probeTicksRemaining > 0
            self.probeTicksRemaining = Self.probeTickLimit
            if !alreadyProbing {
                Logger.debug("Switcher discovery probe started (host saw ⌘-Tab)")
                self.probeTick()
            }
        }
    }

    // MARK: Session polling

    /// Runs on `queue` only. Once the switcher list is on screen, rescan at a
    /// fixed cadence until it disappears. Bounded by the session's lifetime
    /// (the seconds ⌘-Tab is held), so the cost is negligible.
    private func startSessionPollingIfNeeded() {
        guard !sessionPolling else { return }
        sessionPolling = true
        scheduleSessionPollTick()
    }

    private func scheduleSessionPollTick() {
        queue.asyncAfter(deadline: .now() + Self.sessionPollInterval) { [weak self] in
            guard let self, self.isActive.withLock({ $0 }), self.sessionPolling else { return }
            self.scan()
            if self.sessionPolling {
                self.scheduleSessionPollTick()
            }
        }
    }

    /// Runs on `queue` only.
    private func probeTick() {
        guard isActive.withLock({ $0 }), probeTicksRemaining > 0 else { return }
        probeTicksRemaining -= 1
        scan()
        guard attachedList.withLockUnchecked({ $0 == nil }) else {
            probeTicksRemaining = 0
            return
        }
        queue.asyncAfter(deadline: .now() + Self.probeInterval) { [weak self] in
            self?.probeTick()
        }
    }

    // MARK: Dock observer (main)

    private func registerDockObserver() {
        tearDownDockObserver()
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return }
        dockPID = dock.processIdentifier
        let app = AXUIElementCreateApplication(dockPID)
        app.setMessagingTimeout(seconds: Self.messagingTimeout)
        dockApp = app

        var newObserver: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(dockPID, Self.observerCallback, &newObserver) == .success,
              let newObserver else { return }
        observer = newObserver
        for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(newObserver, app, notification as CFString, context)
        }
        // .commonModes so switcher notifications keep arriving while the main
        // run loop is in a tracking mode (menu/drag/scroll).
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func tearDownDockObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        if let dockApp {
            for notification in [kAXCreatedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(observer, dockApp, notification as CFString)
            }
            if let list = attachedList.withLockUnchecked({ list -> AXUIElement? in
                defer { list = nil }
                return list
            }) {
                detachListNotifications(observer: observer, list: list)
            }
        }
        self.observer = nil
        dockApp = nil
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<AppSwitcherObserver>.fromOpaque(refcon).takeUnretainedValue()
        observer.scheduleScan()
    }

    private func startWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let relaunch: (Notification) -> Void = { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock", let self else { return }
            self.registerDockObserver()
            self.scheduleScan()
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

    // MARK: List-element subscription

    /// Subscribes the switcher list element to selection-changed / destroyed on the main
    /// run loop (where the observer's run-loop source lives).
    private func attachListNotifications(_ list: AXUIElement) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let observer = self.observer else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXSelectedChildrenChangedNotification, kAXUIElementDestroyedNotification] {
                let result = AXObserverAddNotification(observer, list, notification as CFString, context)
                if result != .success {
                    Logger.warning("Switcher list notification attach failed", details: "notification=\(notification) error=\(result.rawValue)")
                }
            }
        }
    }

    private func detachListNotifications(observer: AXObserver, list: AXUIElement) {
        for notification in [kAXSelectedChildrenChangedNotification, kAXUIElementDestroyedNotification] {
            AXObserverRemoveNotification(observer, list, notification as CFString)
        }
    }

    private func detachListNotifications(_ list: AXUIElement) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let observer = self.observer else { return }
            self.detachListNotifications(observer: observer, list: list)
        }
    }

    // MARK: Scan (queue only)

    /// Coalesces a burst of AX notifications into a single scan.
    private func scheduleScan() {
        queue.async { [weak self] in
            guard let self, self.isActive.withLock({ $0 }), !self.scanScheduled else { return }
            self.scanScheduled = true
            self.queue.async { [weak self] in
                self?.scanScheduled = false
                self?.scan()
            }
        }
    }

    private func scan() {
        guard isActive.withLock({ $0 }) else { return }

        // Reuse the attached element instead of re-walking the Dock tree each
        // poll. A dead element (read returns nil) means the session ended; a
        // read that *throws* means the Dock isn't answering (hung/overloaded) —
        // session state unknown, so keep it alive and let a later tick decide
        // rather than falsely dismissing mid-session.
        var list = attachedList.withLockUnchecked { $0 }
        if let cached = list {
            do {
                if try cached.subrole() != Self.switcherSubrole {
                    attachedList.withLockUnchecked { $0 = nil }
                    detachListNotifications(cached)
                    list = nil
                }
                unknownReads = 0
            } catch {
                // Dock not answering. Transient hangs ride through, but a Dock
                // that stays wedged must not pin the poll loop (and the host's
                // switcher session) open forever — after ~10s of consecutive
                // no-answers, declare the session over.
                unknownReads += 1
                guard unknownReads >= Self.unknownReadLimit else { return }
                Logger.warning("Dock unresponsive for \(unknownReads) consecutive polls — ending switcher session")
                unknownReads = 0
                attachedList.withLockUnchecked { $0 = nil }
                detachListNotifications(cached)
                list = nil
            }
        }
        if list == nil {
            list = findSwitcherList()
            // Timeouts don't inherit from the app element; bound this element's
            // reads too so a hung Dock fails fast (safe now that timeouts are
            // "unknown", not "closed") instead of blocking the queue ~6s per read.
            _ = list?.setMessagingTimeout(seconds: Self.messagingTimeout)
        }

        // Switcher closed.
        guard let list else {
            sessionPolling = false
            if currentSelection != nil {
                currentSelection = nil
                publishSelection(nil)
                emit(.dismissed)
            }
            return
        }

        // Switcher open — attach to its selection changes once, and poll for the
        // session's lifetime: selection movement and dismissal must never depend
        // on the Dock actually delivering AX notifications (field machines on
        // macOS 26.5 drop them), and a notification-triggered scan can land
        // before the Dock finishes moving the selection, which polling corrects
        // on the next tick.
        let didAttach = attachedList.withLockUnchecked { current -> Bool in
            guard current == nil else { return false }
            current = list
            return true
        }
        if didAttach {
            Logger.debug("Process switcher list found — session tracking active")
            attachListNotifications(list)
        }
        startSessionPollingIfNeeded()

        guard let selection = readSelection(from: list) else { return }
        guard selection != currentSelection else { return }

        let wasOpen = currentSelection != nil
        currentSelection = selection
        publishSelection(selection)
        emit(wasOpen ? .selectionChanged(selection) : .appeared(selection))
    }

    private func emit(_ event: AppSwitcherEvent) {
        guard isActive.withLock({ $0 }) else { return }
        eventSubject.send(event)
    }

    private func publishSelection(_ selection: AppSwitcherSelection?) {
        guard isActive.withLock({ $0 }) else { return }
        selectionSubject.send(selection)
    }

    // MARK: AX reads (queue only)

    private func dockElement() -> AXUIElement {
        let pid = dockPID != 0 ? dockPID : currentDockPID()
        let app = AXUIElementCreateApplication(pid)
        app.setMessagingTimeout(seconds: Self.messagingTimeout)
        return app
    }

    private func currentDockPID() -> pid_t {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier ?? 0
    }

    /// Recursively walks the Dock AX tree for the `AXProcessSwitcherList` element. It only
    /// exists while Cmd+Tab is on screen.
    private func findSwitcherList() -> AXUIElement? {
        findSwitcherList(in: dockElement())
    }

    private func findSwitcherList(in element: AXUIElement) -> AXUIElement? {
        guard let children = try? element.children() else { return nil }
        for child in children {
            if (try? child.subrole()) == Self.switcherSubrole {
                return child
            }
            if let found = findSwitcherList(in: child) {
                return found
            }
        }
        return nil
    }

    private func readSelection(from list: AXUIElement) -> AppSwitcherSelection? {
        guard let selected = try? list.attribute(kAXSelectedChildrenAttribute, as: [AXUIElement].self),
              let item = selected.first else { return nil }

        let title = try? item.title()
        let (pid, bundleID) = resolveApp(for: item, title: title)

        let position = (try? item.position()) ?? .zero
        let size = (try? item.size()) ?? .zero

        return AppSwitcherSelection(
            ownerPID: pid,
            bundleIdentifier: bundleID,
            title: title,
            frame: CGRect(origin: position, size: size)
        )
    }

    /// Resolves the selected item to a running app via its `kAXURLAttribute` bundle,
    /// falling back to matching the AX title against running applications.
    private func resolveApp(for item: AXUIElement, title: String?) -> (pid: pid_t, bundleID: String?) {
        if let nsURL = try? item.attribute(kAXURLAttribute, as: NSURL.self),
           let bundle = Bundle(url: nsURL as URL),
           let bundleID = bundle.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return (app.processIdentifier, bundleID)
        }

        if let title, !title.isEmpty {
            let apps = NSWorkspace.shared.runningApplications
            if let app = apps.first(where: { $0.localizedName == title })
                ?? apps.first(where: { matchesLoosely($0.localizedName, title) }) {
                return (app.processIdentifier, app.bundleIdentifier)
            }
        }

        return (0, nil)
    }

    private func matchesLoosely(_ name: String?, _ title: String) -> Bool {
        guard let name = name?.lowercased(), !name.isEmpty else { return false }
        let lowerTitle = title.lowercased()
        return name.contains(lowerTitle) || lowerTitle.contains(name)
    }
}
