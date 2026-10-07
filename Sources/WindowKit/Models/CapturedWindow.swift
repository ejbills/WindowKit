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

    /// Minimizes the window while its owner app is hidden, so the Dock has nothing on screen to animate.
    /// The app's other windows leave the screen for the ~50-100ms this takes, and a frontmost owner is
    /// activated again afterwards (hiding hands focus to another app). Returns whether the minimize landed.
    mutating func minimizeHidingOwner(reactivate: Bool) async throws -> Bool {
        guard !isMinimized else { return true }
        let axEl = axElement
        let appAx = appAxElement
        let pid = ownerPID
        let landed = try await Self.offMain {
            let landed = try Self.whileOwnerHidden(appAx) {
                try axEl.setAttribute(kAXMinimizedAttribute, value: true)
                return Self.waitUntil { (try? axEl.isMinimized()) == true }
            }
            if landed, reactivate {
                _ = RunningApplicationResolver.application(forProcessIdentifier: pid)?.activate()
            }
            return landed
        }
        if landed { isMinimized = true }
        return landed
    }

    /// Hides the owner app over AX, runs `work` once it is hidden, then unhides it. The app drops an AX
    /// request it hasn't acted on when it unhides, so `work` waits for its own result before returning.
    private static func whileOwnerHidden(_ appAx: AXUIElement, _ work: () throws -> Bool) throws -> Bool {
        let wasHidden = (try? appAx.attribute(kAXHiddenAttribute, as: Bool.self)) == true
        if !wasHidden {
            try appAx.setAttribute(kAXHiddenAttribute, value: true)
            guard waitUntil({ (try? appAx.attribute(kAXHiddenAttribute, as: Bool.self)) == true }) else {
                try? appAx.setAttribute(kAXHiddenAttribute, value: false)
                return false
            }
        }
        defer {
            if !wasHidden { try? appAx.setAttribute(kAXHiddenAttribute, value: false) }
        }
        return try work()
    }

    private static func waitUntil(timeout: TimeInterval = 0.4, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(2000)
        } while Date() < deadline
        return false
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
