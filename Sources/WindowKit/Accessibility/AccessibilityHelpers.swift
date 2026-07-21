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

private enum BruteForceGate {
    static let lock = NSLock()
    nonisolated(unsafe) static var lastRuns: [pid_t: TimeInterval] = [:]
    static let staleInterval: TimeInterval = 60

    static func shouldRun(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastRun = lastRuns[pid] else { return true }
        return ProcessInfo.processInfo.systemUptime - lastRun > staleInterval
    }

    static func record(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        if lastRuns.count > 512 {
            lastRuns = lastRuns.filter { kill($0.key, 0) == 0 }
        }
        lastRuns[pid] = ProcessInfo.processInfo.systemUptime
    }
}

extension AXUIElement {
    /// AX enumeration with brute-force fallback for windows AX misses.
    public static func allWindows(forPID pid: pid_t) -> [AXUIElement] {
        var resultSet = Set<AXUIElement>()

        let appElement = application(pid: pid)

        if let windows = try? appElement.windows() {
            resultSet.formUnion(windows)
        }

        if BruteForceGate.shouldRun(pid: pid) {
            let bruteForceWindows = enumerateWindowsByBruteForce(pid: pid)
            BruteForceGate.record(pid: pid)
            resultSet.formUnion(bruteForceWindows)
        }

        return Array(resultSet)
    }

    private static func enumerateWindowsByBruteForce(pid: pid_t) -> [AXUIElement] {
        var results: [AXUIElement] = []

        for elementID: UInt64 in 0 ..< 1000 {
            guard let element = axCreateElementFromToken(pid, elementID) else { continue }

            guard let subrole = try? element.subrole(),
                  subrole == kAXStandardWindowSubrole as String ||
                  subrole == kAXDialogSubrole as String else {
                continue
            }

            results.append(element)
        }

        return results
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
