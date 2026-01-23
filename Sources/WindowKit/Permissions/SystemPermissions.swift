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
    private static var cachedScreenRecording: Bool = checkScreenRecordingDirect()
    private var timer: AnyCancellable?
    private let lock = NSLock()

    private init() {
        self.currentState = PermissionState(
            accessibilityGranted: Self.checkAccessibility(),
            screenCaptureGranted: Self.cachedScreenRecording
        )
        startPolling()
    }

    deinit { timer?.cancel() }

    public func refresh() {
        let accessibility = Self.checkAccessibility()
        let screenRecording = Self.checkScreenRecordingDirect()
        lock.lock()
        Self.cachedScreenRecording = screenRecording
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.currentState = PermissionState(
                accessibilityGranted: accessibility,
                screenCaptureGranted: screenRecording
            )
        }
    }

    public static func hasAccessibility() -> Bool { checkAccessibility() }
    public static func hasScreenRecording() -> Bool { cachedScreenRecording }

    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public func requestScreenRecording() {
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

    private static func checkScreenRecordingDirect() -> Bool {
        let stream = CGDisplayStream(
            dispatchQueueDisplay: CGMainDisplayID(),
            outputWidth: 1, outputHeight: 1,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: nil, queue: .main,
            handler: { _, _, _, _ in }
        )
        let hasPermission = stream != nil
        stream?.stop()
        return hasPermission
    }

    private func startPolling() {
        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }
}
