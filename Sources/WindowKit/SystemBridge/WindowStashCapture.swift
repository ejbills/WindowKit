import Cocoa

/// Moves every window that matching processes create while the capture runs into a Space no display shows,
/// before the owner can order it in. Window IDs are allocated in sequence, so the capture starts after a
/// frontier ID (`newestWindowID()`) and probes the next few IDs every millisecond until `end()`.
public final class WindowStashCapture: @unchecked Sendable {
    private static let lookahead: CGWindowID = 8
    private static let probeInterval: useconds_t = 1000

    private let spaceID: CGSSpaceID
    private let ownerMatches: @Sendable (pid_t) -> Bool
    private let connection = cgsMainConnection()
    private let lock = NSLock()
    private let watchEnded = DispatchSemaphore(value: 0)
    private var cursor: CGWindowID
    private var isWatching = true
    private var windows: [CGWindowID] = []
    private var matchByPID: [pid_t: Bool] = [:]

    /// Captured windows that WindowServer still has ordered in.
    public var orderedInWindowIDs: [CGWindowID] {
        lock.withLock { windows }.filter { cgsWindowIsOrderedIn(connection, $0) == true }
    }

    private init(spaceID: CGSSpaceID, frontier: CGWindowID, ownerMatches: @escaping @Sendable (pid_t) -> Bool) {
        self.spaceID = spaceID
        self.ownerMatches = ownerMatches
        cursor = frontier
    }

    /// The newest window ID, read off a window created and closed for the purpose.
    @MainActor
    public static func newestWindowID() -> CGWindowID {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowID = CGWindowID(window.windowNumber)
        window.close()
        return windowID
    }

    /// Creates the stash Space and starts capturing windows with IDs past `frontier` whose owner pid matches.
    public static func begin(after frontier: CGWindowID, capturingWindowsOf ownerMatches: @escaping @Sendable (pid_t) -> Bool) throws -> WindowStashCapture {
        let capture = try WindowStashCapture(spaceID: WindowStash.createSpace(), frontier: frontier, ownerMatches: ownerMatches)
        let thread = Thread { capture.watch() }
        thread.qualityOfService = .userInteractive
        thread.start()
        return capture
    }

    /// Waits until no captured window is ordered in. False if one still is at the deadline.
    public func waitUntilOrderedOut(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if orderedInWindowIDs.isEmpty { return true }
            usleep(2000)
        } while Date() < deadline
        return false
    }

    /// Stops capturing and destroys the Space, unless a captured window is still ordered in. Returns whether
    /// the Space was destroyed.
    public func end() -> Bool {
        lock.withLock { isWatching = false }
        watchEnded.wait()
        guard orderedInWindowIDs.isEmpty else { return false }
        try? WindowStash.destroySpace(spaceID)
        return true
    }

    private func watch() {
        while lock.withLock({ isWatching }) {
            var found: [CGWindowID] = []
            for windowID in (cursor + 1) ... (cursor + Self.lookahead) {
                guard let pid = cgsWindowOwnerPID(connection, windowID) else { continue }
                cursor = windowID
                if matches(pid) {
                    found.append(windowID)
                }
            }
            if !found.isEmpty {
                try? WindowStash.move(windowIDs: found, toSpace: spaceID)
                lock.withLock { windows += found }
            }
            usleep(Self.probeInterval)
        }
        watchEnded.signal()
    }

    private func matches(_ pid: pid_t) -> Bool {
        if let known = matchByPID[pid] { return known }
        let match = ownerMatches(pid)
        matchByPID[pid] = match
        return match
    }
}
