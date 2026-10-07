@preconcurrency import ApplicationServices
import Cocoa
import ScreenCaptureKit

public struct CapturedWindow: Identifiable, Hashable, @unchecked Sendable {
    public let id: CGWindowID
    public let title: String?
    public let ownerBundleID: String?
    public let ownerPID: pid_t
    public let bounds: CGRect
    public internal(set) var isMinimized: Bool
    public internal(set) var isFullscreen: Bool
    public internal(set) var isOwnerHidden: Bool
    public let isVisible: Bool
    public let owningDisplayID: CGDirectDisplayID?
    public let desktopSpace: Int?
    public let lastInteractionTime: Date
    public let creationTime: Date

    internal var cachedPreview: CGImage?
    internal var previewTimestamp: Date?

    public let axElement: AXUIElement
    public let appAxElement: AXUIElement
    public let closeButton: AXUIElement?
    public let subrole: String?

    public var preview: CGImage? { cachedPreview }
    public var ownerApplication: NSRunningApplication? {
        RunningApplicationResolver.application(forProcessIdentifier: ownerPID)
    }

    public init(
        id: CGWindowID,
        title: String?,
        ownerBundleID: String?,
        ownerPID: pid_t,
        bounds: CGRect,
        isMinimized: Bool,
        isFullscreen: Bool,
        isOwnerHidden: Bool,
        isVisible: Bool,
        owningDisplayID: CGDirectDisplayID? = nil,
        desktopSpace: Int?,
        lastInteractionTime: Date,
        creationTime: Date,
        axElement: AXUIElement,
        appAxElement: AXUIElement,
        closeButton: AXUIElement? = nil,
        subrole: String? = nil
    ) {
        self.id = id
        self.title = title
        self.ownerBundleID = ownerBundleID
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.isOwnerHidden = isOwnerHidden
        self.isVisible = isVisible
        self.owningDisplayID = owningDisplayID
        self.desktopSpace = desktopSpace
        self.lastInteractionTime = lastInteractionTime
        self.creationTime = creationTime
        self.axElement = axElement
        self.appAxElement = appAxElement
        self.closeButton = closeButton
        self.subrole = subrole
        self.cachedPreview = nil
        self.previewTimestamp = nil
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: CapturedWindow, rhs: CapturedWindow) -> Bool {
        lhs.id == rhs.id && lhs.ownerPID == rhs.ownerPID && lhs.axElement == rhs.axElement
    }

    func replacingCreationTime(_ creationTime: Date) -> CapturedWindow {
        replacing(title: title, creationTime: creationTime)
    }

    func replacingTitle(_ title: String) -> CapturedWindow {
        replacing(title: title, creationTime: creationTime)
    }

    private func replacing(title: String?, creationTime: Date) -> CapturedWindow {
        var window = CapturedWindow(
            id: id,
            title: title,
            ownerBundleID: ownerBundleID,
            ownerPID: ownerPID,
            bounds: bounds,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isOwnerHidden: isOwnerHidden,
            isVisible: isVisible,
            owningDisplayID: owningDisplayID,
            desktopSpace: desktopSpace,
            lastInteractionTime: lastInteractionTime,
            creationTime: creationTime,
            axElement: axElement,
            appAxElement: appAxElement,
            closeButton: closeButton,
            subrole: subrole
        )
        window.cachedPreview = cachedPreview
        window.previewTimestamp = previewTimestamp
        return window
    }
}

extension CapturedWindow {
    private static let axManipulationQueue = DispatchQueue(label: "com.windowkit.axManipulation", qos: .userInitiated)

    static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            axManipulationQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public mutating func bringToFront() async throws {
        guard let app = ownerApplication else {
            throw WindowManipulationError.applicationNotFound
        }

        let axEl = axElement
        let wid = id
        let pid = ownerPID

        let (newHidden, newMinimized) = try await Self.offMain {
            var hidden = app.isHidden
            var minimized = false
            if hidden {
                app.unhide()
                hidden = false
            }
            if (try? axEl.isMinimized()) == true {
                try axEl.setAttribute(kAXMinimizedAttribute, value: false)
                minimized = false
            }

            var psn = ProcessSerialNumber()
            _ = GetProcessForPID(pid, &psn)
            _ = _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)

            var bytes = [UInt8](repeating: 0, count: 0x100)
            bytes[0x04] = 0xF8
            bytes[0x3A] = 0x10
            var widCopy = UInt32(wid)
            memcpy(&bytes[0x3C], &widCopy, MemoryLayout<UInt32>.size)
            // Mouse-down only, far off the frame: makes the window key without clicking content
            // or its resize grab region (two quick down/up pairs there resize like a corner double-click).
            var clickPoint = CGPoint(x: 300_000, y: 300_000)
            memcpy(&bytes[0x20], &clickPoint, MemoryLayout<CGPoint>.size)
            bytes[0x08] = 0x01
            _ = SLPSPostEventRecordTo(&psn, &bytes)

            try axEl.performAction(kAXRaiseAction)
            try axEl.setAttribute(kAXMainAttribute, value: true)
            app.activate()
            return (hidden, minimized)
        }
        isOwnerHidden = newHidden
        if !newMinimized { isMinimized = false }
        await MainActor.run {
            WindowKit.shared.touchWindow(id: wid, pid: pid)
        }
    }

    @discardableResult
    public mutating func toggleMinimize() async throws -> Bool {
        let axEl = axElement
        if isMinimized {
            try await Self.offMain {
                if let button = try? axEl.minimizeButton() {
                    try button.performAction(kAXPressAction)
                } else {
                    try axEl.setAttribute(kAXMinimizedAttribute, value: false)
                }
            }
            try await bringToFront()
            isMinimized = false
            return false
        } else {
            try await Self.offMain {
                if let button = try? axEl.minimizeButton() {
                    try button.performAction(kAXPressAction)
                } else {
                    try axEl.setAttribute(kAXMinimizedAttribute, value: true)
                }
            }
            isMinimized = true
            return true
        }
    }

    public mutating func minimize() async throws {
        guard !isMinimized else { return }
        let axEl = axElement
        try await Self.offMain {
            if let button = try? axEl.minimizeButton() {
                try button.performAction(kAXPressAction)
            } else {
                try axEl.setAttribute(kAXMinimizedAttribute, value: true)
            }
        }
        isMinimized = true
    }

    public mutating func restore() async throws {
        guard isMinimized else { return }
        let axEl = axElement
        try await Self.offMain {
            if let button = try? axEl.minimizeButton() {
                try button.performAction(kAXPressAction)
            } else {
                try axEl.setAttribute(kAXMinimizedAttribute, value: false)
            }
        }
        try await bringToFront()
        isMinimized = false
    }

    private static let ownerHideMessagingTimeout: Float = 0.25
    private static let ownerHideTimeout: TimeInterval = 0.4
    private static let ownerHideMinimizeTimeoutPerWindow: TimeInterval = 0.1
    private static let ownerHideMinimizeTimeoutLimit: TimeInterval = 1.5

    /// Minimizes the windows, all owned by `pid`, while the owner app is hidden so the Dock has nothing on
    /// screen to animate, and returns the ids of those now minimized. Each AX call uses a short messaging
    /// timeout, the unhide is confirmed, and a frontmost owner is activated again whenever it was hidden.
    /// Blocks for the ~50-100ms the app's windows are off screen; call off the main thread.
    static func minimizeHidingOwner(pid: pid_t, windows: [(id: CGWindowID, element: AXUIElement)], reactivate: Bool) -> Set<CGWindowID> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ownerHideMessagingTimeout)
        var minimized = Set<CGWindowID>()
        var pending: [(id: CGWindowID, element: AXUIElement)] = []
        for window in boundedElements(of: windows, in: app) {
            if (try? window.element.isMinimized()) == true {
                minimized.insert(window.id)
            } else if (try? window.element.isFullscreen()) != true {
                pending.append(window)
            }
        }
        guard !pending.isEmpty else { return minimized }

        let hidesOwner = (try? app.attribute(kAXHiddenAttribute, as: Bool.self)) != true
        if hidesOwner {
            try? app.setAttribute(kAXHiddenAttribute, value: true)
            guard ConcurrencyHelpers.poll(timeout: ownerHideTimeout, { (try? app.attribute(kAXHiddenAttribute, as: Bool.self)) == true }) else {
                revealOwner(app, pid: pid, reactivate: reactivate)
                return minimized
            }
        }
        for window in pending {
            try? window.element.setAttribute(kAXMinimizedAttribute, value: true)
        }
        let timeout = min(ownerHideTimeout + ownerHideMinimizeTimeoutPerWindow * Double(pending.count - 1), ownerHideMinimizeTimeoutLimit)
        _ = ConcurrencyHelpers.poll(timeout: timeout) {
            pending.removeAll { window in
                guard (try? window.element.isMinimized()) == true else { return false }
                minimized.insert(window.id)
                return true
            }
            return pending.isEmpty
        }
        if hidesOwner {
            revealOwner(app, pid: pid, reactivate: reactivate)
        }
        for window in pending where (try? window.element.isMinimized()) == true {
            minimized.insert(window.id)
        }
        return minimized
    }

    /// The windows' elements as listed by `app`, which carries a short messaging timeout, so a busy owner can't
    /// hold one read for the global timeout. A window the list misses keeps its shared element.
    private static func boundedElements(
        of windows: [(id: CGWindowID, element: AXUIElement)],
        in app: AXUIElement
    ) -> [(id: CGWindowID, element: AXUIElement)] {
        let listed = (try? app.windows()) ?? []
        return windows.map { window in
            guard let element = listed.first(where: { CFEqual($0, window.element) }) else { return window }
            AXUIElementSetMessagingTimeout(element, ownerHideMessagingTimeout)
            return (window.id, element)
        }
    }

    /// Unhides the owner over AX and confirms it, unhiding through LaunchServices when the app doesn't answer,
    /// then activates it again if it was frontmost (hiding hands focus to another app).
    private static func revealOwner(_ app: AXUIElement, pid: pid_t, reactivate: Bool) {
        try? app.setAttribute(kAXHiddenAttribute, value: false)
        let revealed = ConcurrencyHelpers.poll(timeout: ownerHideTimeout) {
            (try? app.attribute(kAXHiddenAttribute, as: Bool.self)) == false
        }
        guard !revealed || reactivate else { return }
        let application = RunningApplicationResolver.application(forProcessIdentifier: pid)
        if !revealed {
            Logger.warning("Owner didn't unhide over AX; unhiding through LaunchServices", details: "pid=\(pid)")
            _ = application?.unhide()
        }
        if reactivate {
            _ = application?.activate()
        }
    }

    @discardableResult
    public mutating func toggleHidden() async throws -> Bool {
        let newHiddenState = !isOwnerHidden
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: newHiddenState)
        }
        if !newHiddenState {
            try await bringToFront()
        }
        isOwnerHidden = newHiddenState
        return newHiddenState
    }

    public mutating func hide() async throws {
        guard !isOwnerHidden else { return }
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: true)
        }
        isOwnerHidden = true
    }

    public mutating func unhide() async throws {
        guard isOwnerHidden else { return }
        let appAx = appAxElement
        try await Self.offMain {
            try appAx.setAttribute(kAXHiddenAttribute, value: false)
        }
        try await bringToFront()
        isOwnerHidden = false
    }

    public func toggleFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            if let button = try? axEl.zoomButton() {
                try button.performAction(kAXPressAction)
            } else {
                let isCurrentlyFullscreen = (try? axEl.isFullscreen()) ?? false
                try axEl.setAttribute("AXFullScreen", value: !isCurrentlyFullscreen)
            }
        }
    }

    public func enterFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            if let button = try? axEl.zoomButton(), (try? axEl.isFullscreen()) != true {
                try button.performAction(kAXPressAction)
            } else {
                try axEl.setAttribute("AXFullScreen", value: true)
            }
        }
    }

    public func exitFullScreen() async throws {
        let axEl = axElement
        try await Self.offMain {
            if let button = try? axEl.zoomButton(), (try? axEl.isFullscreen()) == true {
                try button.performAction(kAXPressAction)
            } else {
                try axEl.setAttribute("AXFullScreen", value: false)
            }
        }
    }

    public func close() async throws {
        let button = closeButton ?? (try? axElement.closeButton())
        guard let button else {
            throw WindowManipulationError.closeButtonNotFound
        }
        try await Self.offMain {
            try button.performAction(kAXPressAction)
        }
    }

    public func quit(force: Bool = false) {
        guard let app = ownerApplication else { return }
        if force {
            app.forceTerminate()
        } else {
            app.terminate()
        }
    }

    public func setPosition(_ position: CGPoint) async throws {
        guard let positionValue = AXValue.from(point: position) else {
            throw WindowManipulationError.invalidValue
        }
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute(kAXPositionAttribute, value: positionValue)
        }
    }

    public func setSize(_ size: CGSize) async throws {
        guard let sizeValue = AXValue.from(size: size) else {
            throw WindowManipulationError.invalidValue
        }
        let axEl = axElement
        try await Self.offMain {
            try axEl.setAttribute(kAXSizeAttribute, value: sizeValue)
        }
    }

    public func setPositionAndSize(position: CGPoint, size: CGSize) async throws {
        try await setPosition(position)
        try await setSize(size)
    }
}

public enum WindowManipulationError: Error, LocalizedError {
    case applicationNotFound
    case closeButtonNotFound
    case invalidValue
    case screenNotFound

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            return "The owning application could not be found"
        case .closeButtonNotFound:
            return "The window's close button could not be found"
        case .invalidValue:
            return "Could not create AXValue for the given value"
        case .screenNotFound:
            return "Could not resolve a target screen for the window"
        }
    }
}

protocol WindowPropertySource {
    var windowID: CGWindowID { get }
    var frame: CGRect { get }
    var title: String? { get }
    var owningBundleIdentifier: String? { get }
    var owningProcessID: pid_t? { get }
    var isOnScreen: Bool { get }
    var windowLayer: Int { get }
}

@available(macOS 12.3, *)
extension SCWindow: WindowPropertySource {
    var owningBundleIdentifier: String? { owningApplication?.bundleIdentifier }
    var owningProcessID: pid_t? { owningApplication?.processID }
}

struct FallbackWindowSource: WindowPropertySource {
    let windowID: CGWindowID
    var frame: CGRect { .zero }
    var title: String? { nil }
    var owningBundleIdentifier: String? { nil }
    var owningProcessID: pid_t? { nil }
    var isOnScreen: Bool { true }
    var windowLayer: Int { 0 }
}

public enum WindowEvent: Sendable {
    case windowAppeared(CapturedWindow)
    case windowDisappeared(CGWindowID)
    case windowChanged(CapturedWindow)
    /// Raw AX window created/destroyed activity for a tracked app, emitted even when
    /// the affected window never enters tracking (borderless fullscreen windows,
    /// panels without close/minimize buttons). Lets clients re-derive display-level
    /// state — e.g. fullscreen presence — that the cached window list cannot express.
    /// Deliberately excludes focus-change notifications: those fire on every app
    /// switch and would turn any subscriber into an ambient-energy cost.
    case windowActivityDetected(pid_t)
    case previewCaptured(CGWindowID, CGImage)
    case notificationBannerChanged
    /// macOS reported that the system woke from sleep.
    case systemWoke
    /// WindowKit finished its post-wake AX recovery and full scan.
    case wakeRecoveryCompleted
}
