import Cocoa
import Combine

public struct PermissionState: Sendable, Equatable {
    public let accessibilityGranted: Bool
    public let screenCaptureGranted: Bool
    public var allGranted: Bool { accessibilityGranted && screenCaptureGranted }

    public init(accessibilityGranted: Bool, screenCaptureGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenCaptureGranted = screenCaptureGranted
    }
}

public final class SystemPermissions: ObservableObject, @unchecked Sendable {
    public static let shared = SystemPermissions()

    @Published public private(set) var currentState: PermissionState
    private static var cachedScreenRecording: Bool = checkScreenRecordingQuiet()
    private var timer: AnyCancellable?
    private let lock = NSLock()

    /// When true, screen recording permission is never checked or requested.
    /// All screen-recording-gated APIs (SCShareableContent, CGDisplayStream,
    /// CGSHWCaptureWindowList) are skipped; the library runs on Accessibility only.
    static var headless: Bool = false

    private init() {
        self.currentState = PermissionState(
            accessibilityGranted: Self.checkAccessibility(),
            screenCaptureGranted: Self.headless ? false : Self.cachedScreenRecording
        )
        startPolling()
    }

    deinit { timer?.cancel() }

    public func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let accessibility = Self.checkAccessibility()
            let screenRecording: Bool
            if Self.headless {
                screenRecording = false
            } else {
                screenRecording = Self.checkScreenRecordingQuiet()
            }
            self?.lock.lock()
            Self.cachedScreenRecording = screenRecording
            self?.lock.unlock()
            DispatchQueue.main.async {
                self?.currentState = PermissionState(
                    accessibilityGranted: accessibility,
                    screenCaptureGranted: screenRecording
                )
            }
        }
    }

    public static func hasAccessibility() -> Bool { checkAccessibility() }
    public static func hasScreenRecording() -> Bool { headless ? false : cachedScreenRecording }

    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public func requestScreenRecording() {
        guard !Self.headless else {
            Logger.debug("requestScreenRecording skipped — headless mode is active")
            return
        }
        _ = CGDisplayStream(
            dispatchQueueDisplay: CGMainDisplayID(),
            outputWidth: 1, outputHeight: 1,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil, queue: .main,
            handler: { _, _, _, _ in }
        )
    }

    public func openPrivacySettings(for permission: PermissionType) {
        let urlString = switch permission {
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    public enum PermissionType: Sendable {
        case accessibility
        case screenRecording
    }

    private static func checkAccessibility() -> Bool { AXIsProcessTrusted() }

    /// Checks screen recording permission without triggering a system prompt.
    /// Uses CGPreflightScreenCaptureAccess which silently queries the TCC database.
    private static func checkScreenRecordingQuiet() -> Bool {
        if headless { return false }
        return CGPreflightScreenCaptureAccess()
    }

    private func startPolling() {
        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }
}
