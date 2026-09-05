import ApplicationServices
import Cocoa

public enum AccessibilityError: Error {
    case operationFailed
    case timeout
    case invalidElement
}

extension AXUIElement {
    func axCallWithThrow<T>(_ result: AXError, _ value: inout T) throws -> T? {
        switch result {
        case .success:
            return value
        case .cannotComplete:
            throw AccessibilityError.operationFailed
        default:
            return nil
        }
    }

    public func attribute<T>(_ key: String, as type: T.Type) throws -> T? {
        var value: AnyObject?
        return try axCallWithThrow(AXUIElementCopyAttributeValue(self, key as CFString, &value), &value) as? T
    }

    private func valueAttribute<T>(_ key: String, _ target: T, _ type: AXValueType) throws -> T? {
        guard let axValue = try attribute(key, as: AXValue.self) else { return nil }
        var value = target
        let success = withUnsafeMutablePointer(to: &value) { ptr in
            AXValueGetValue(axValue, type, ptr)
        }
        return success ? value : nil
    }

    public func windowID() throws -> CGWindowID? {
        var id = CGWindowID(0)
        return try axCallWithThrow(_AXUIElementGetWindow(self, &id), &id)
    }

    public func processID() throws -> pid_t? {
        var pid = pid_t(0)
        return try axCallWithThrow(AXUIElementGetPid(self, &pid), &pid)
    }

    public func position() throws -> CGPoint? {
        try valueAttribute(kAXPositionAttribute, CGPoint.zero, .cgPoint)
    }

    public func size() throws -> CGSize? {
        try valueAttribute(kAXSizeAttribute, CGSize.zero, .cgSize)
    }

    public func title() throws -> String? {
        try attribute(kAXTitleAttribute, as: String.self)
    }

    public func role() throws -> String? {
        try attribute(kAXRoleAttribute, as: String.self)
    }

    public func subrole() throws -> String? {
        try attribute(kAXSubroleAttribute, as: String.self)
    }

    public func isMinimized() throws -> Bool {
        (try attribute(kAXMinimizedAttribute, as: Bool.self)) ?? false
    }

    public func isFullscreen() throws -> Bool {
        (try attribute("AXFullScreen", as: Bool.self)) ?? false
    }

    public func isMainWindow() throws -> Bool {
        (try attribute(kAXMainAttribute, as: Bool.self)) ?? false
    }

    public func parent() throws -> AXUIElement? {
        try attribute(kAXParentAttribute, as: AXUIElement.self)
    }

    public func children() throws -> [AXUIElement]? {
        try attribute(kAXChildrenAttribute, as: [AXUIElement].self)
    }

    public func windows() throws -> [AXUIElement]? {
        try attribute(kAXWindowsAttribute, as: [AXUIElement].self)
    }

    public func focusedWindow() throws -> AXUIElement? {
        try attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
    }

    public func closeButton() throws -> AXUIElement? {
        try attribute(kAXCloseButtonAttribute, as: AXUIElement.self)
    }

    public func minimizeButton() throws -> AXUIElement? {
        try attribute(kAXMinimizeButtonAttribute, as: AXUIElement.self)
    }

    public func zoomButton() throws -> AXUIElement? {
        try attribute(kAXZoomButtonAttribute, as: AXUIElement.self)
    }

    public func setAttribute(_ key: String, value: Any) throws {
        var unused: Void = ()
        try axCallWithThrow(AXUIElementSetAttributeValue(self, key as CFString, value as CFTypeRef), &unused)
    }

    public func performAction(_ action: String) throws {
        var unused: Void = ()
        try axCallWithThrow(AXUIElementPerformAction(self, action as CFString), &unused)
    }

    public func addNotification(_ observer: AXObserver, _ notification: String) throws {
        let result = AXObserverAddNotification(observer, self, notification as CFString, nil)
        if result != .success && result != .notificationAlreadyRegistered &&
           result != .notificationUnsupported && result != .notImplemented {
            throw AccessibilityError.operationFailed
        }
    }
}

extension AXUIElement {
    public static func application(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func systemWide() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    /// Override AX messaging timeout (default ~6s) to fail fast on unresponsive apps.
    @discardableResult
    public func setMessagingTimeout(seconds: Float) -> Bool {
        AXUIElementSetMessagingTimeout(self, seconds) == .success
    }
}

// MARK: - AX Readiness Probe

/// Probes Finder's AX tree to detect post-wake AX subsystem degradation.
public func isAccessibilityReady() -> Bool {
    guard let finder = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.apple.finder" }) else {
        return false
    }

    let app = AXUIElementCreateApplication(finder.processIdentifier)

    app.setMessagingTimeout(seconds: 1.0)

    guard let role = try? app.role(), role == kAXApplicationRole as String else {
        return false
    }

    guard let windows = try? app.windows(), !windows.isEmpty else {
        return false
    }

    // Reject partial-init state where app element is returned as its own child
    return windows.contains { element in
        guard let childRole = try? element.role() else { return false }
        return childRole == kAXWindowRole as String
    }
}

/// Rate limiting and memory for the brute-force AX token sweep.
///
/// Some processes publish CG windows that have no AX element at all (measured:
/// Stage Manager's `WindowManager` with 13, plus `loginwindow` and agent apps),
/// so a sweep driven purely by "CG knows a window AX didn't reach" would run to
/// its time budget for those PIDs on every attempt, forever. Window IDs already
/// swept for and not found are therefore remembered, and a sweep cut short by
/// its budget resumes from where it stopped rather than rescanning the prefix.
private enum BruteForceGate {
    static let lock = NSLock()
    nonisolated(unsafe) static var lastRuns: [pid_t: TimeInterval] = [:]
    nonisolated(unsafe) static var sweepCursors: [pid_t: UInt64] = [:]
    nonisolated(unsafe) static var unfindable: [pid_t: Set<CGWindowID>] = [:]
    static let staleInterval: TimeInterval = 60
    static let maxUnfindablePerPID = 128

    /// Drops window IDs a completed sweep already failed to find.
    static func pending(pid: pid_t, unreached: Set<CGWindowID>) -> Set<CGWindowID> {
        lock.lock()
        defer { lock.unlock() }
        guard let known = unfindable[pid] else { return unreached }
        return unreached.subtracting(known)
    }

    static func shouldRun(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastRun = lastRuns[pid] else { return true }
        return ProcessInfo.processInfo.systemUptime - lastRun > staleInterval
    }

    static func cursor(pid: pid_t) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sweepCursors[pid] ?? 0
    }

    /// `nextCursor` is nil when the sweep covered the whole token range; only
    /// then is `stillMissing` durable enough to suppress future sweeps.
    static func record(pid: pid_t, nextCursor: UInt64?, stillMissing: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }

        if lastRuns.count > 512 {
            let live = Set(lastRuns.keys.filter { kill($0, 0) == 0 })
            lastRuns = lastRuns.filter { live.contains($0.key) }
            sweepCursors = sweepCursors.filter { live.contains($0.key) }
            unfindable = unfindable.filter { live.contains($0.key) }
        }

        lastRuns[pid] = ProcessInfo.processInfo.systemUptime

        guard let nextCursor else {
            sweepCursors[pid] = 0
            guard !stillMissing.isEmpty else { return }
            var known = unfindable[pid] ?? []
            known.formUnion(stillMissing)
            if known.count > maxUnfindablePerPID {
                known = Set(known.sorted().suffix(maxUnfindablePerPID))
            }
            unfindable[pid] = known
            return
        }

        sweepCursors[pid] = nextCursor
    }
}

extension AXUIElement {
    /// Highest AX element token probed by the brute-force sweep. An app numbers
    /// its AX elements from a counter covering every element it has ever vended,
    /// not just windows, so a long-lived app's newer windows sit far above the
    /// window count (measured: a Firefox window at token 13066).
    private static let bruteForceTokenLimit: UInt64 = 65536

    /// Wall-clock ceiling for one sweep. A window ID present in the CG list with
    /// no AX element behind it can never be found, and without this the sweep
    /// would run to the token limit on every attempt.
    private static let bruteForceTimeBudget: TimeInterval = 0.5

    /// AX enumeration with brute-force fallback for windows AX misses.
    ///
    /// `seeking` is the set of window IDs the caller knows exist (from the CG
    /// window list) and wants elements for. The brute-force sweep runs only when
    /// `kAXWindows` failed to account for one of them, and stops as soon as they
    /// are all found. Passing an empty set skips the sweep entirely.
    public static func allWindows(forPID pid: pid_t, seeking: Set<CGWindowID> = []) -> [AXUIElement] {
        var resultSet = Set<AXUIElement>()

        let appElement = application(pid: pid)

        if let windows = try? appElement.windows() {
            resultSet.formUnion(windows)
        }

        var unreached = seeking
        for element in resultSet {
            if let windowID = axElementWindowID(element) {
                unreached.remove(windowID)
            }
        }

        unreached = BruteForceGate.pending(pid: pid, unreached: unreached)
        guard !unreached.isEmpty, BruteForceGate.shouldRun(pid: pid) else {
            return Array(resultSet)
        }

        let sweep = enumerateWindowsByBruteForce(
            pid: pid,
            seeking: unreached,
            from: BruteForceGate.cursor(pid: pid)
        )
        BruteForceGate.record(pid: pid, nextCursor: sweep.nextCursor, stillMissing: sweep.stillMissing)
        resultSet.formUnion(sweep.elements)

        return Array(resultSet)
    }

    /// Walks AX element tokens looking for the windows in `seeking`.
    ///
    /// Deliberately does NOT stop on consecutive attribute failures: tokens are
    /// sparse, and the gaps between live elements are far wider than any small
    /// failure run (measured: bailing after two failures stops at token 4 and
    /// finds nothing for Firefox).
    private static func enumerateWindowsByBruteForce(
        pid: pid_t,
        seeking: Set<CGWindowID>,
        from cursor: UInt64
    ) -> (elements: [AXUIElement], stillMissing: Set<CGWindowID>, nextCursor: UInt64?) {
        var results: [AXUIElement] = []
        var unreached = seeking
        let deadline = ProcessInfo.processInfo.systemUptime + bruteForceTimeBudget
        var sinceClockRead = 0
        let start = cursor < bruteForceTokenLimit ? cursor : 0

        for elementID in start ..< bruteForceTokenLimit {
            if unreached.isEmpty {
                return (results, [], nil)
            }

            sinceClockRead += 1
            if sinceClockRead >= 256 {
                sinceClockRead = 0
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    Logger.debug("Brute-force sweep paused on time budget", details: "pid=\(pid), token=\(elementID), unreached=\(unreached.count)")
                    return (results, unreached, elementID)
                }
            }

            guard let element = axCreateElementFromToken(pid, elementID) else { continue }

            guard let subrole = try? element.subrole(),
                  subrole == kAXStandardWindowSubrole as String ||
                  subrole == kAXDialogSubrole as String else {
                continue
            }

            guard let windowID = axElementWindowID(element), unreached.contains(windowID) else {
                continue
            }

            unreached.remove(windowID)
            results.append(element)
        }

        return (results, unreached, nil)
    }
}

extension AXUIElement: @retroactive Hashable {
    public static func == (lhs: AXUIElement, rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(self))
    }
}
