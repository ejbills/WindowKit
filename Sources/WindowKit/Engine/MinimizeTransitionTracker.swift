import AppKit
import ApplicationServices
import Combine
import os

/// Reports windows the moment the native Dock starts minimizing them. The Dock adds an
/// `AXMinimizedWindowDockItem` ~30ms before the minimize animation is visible, while the
/// owner app's `kAXWindowMiniaturizedNotification` only arrives when the ~0.5s animation
/// ends. The item carries nothing but the window title; `WindowKit` resolves it to a
/// cached window. Needs the native Dock's "Minimize windows into application icon" off,
/// since that mode creates no per-window item.
final class MinimizeTransitionTracker: @unchecked Sendable {
    private static let messagingTimeout: Float = 0.25

    private let queue = DispatchQueue(label: "com.windowkit.minimizeTransitions", qos: .userInteractive)

    /// Titles of windows whose minimize just began, sent on a background queue.
    var titlesPublisher: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }
    private let subject = PassthroughSubject<String, Never>()

    private let isActive = OSAllocatedUnfairLock(initialState: false)
    private let dockObserver = DockAXObserver(runLoopMode: .commonModes)

    init() {}
    deinit { stop() }

    func start() {
        guard !isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = true }
        Logger.info("Starting minimize transition tracking")
        dockObserver.onCreated = { [weak self] element in self?.itemCreated(element) }
        dockObserver.start()
    }

    func stop() {
        guard isActive.withLock({ $0 }) else { return }
        isActive.withLock { $0 = false }
        Logger.info("Stopping minimize transition tracking")
        dockObserver.stop()
    }

    /// Reads the new item off the main thread with a short timeout, so a wedged Dock never stalls the caller.
    private func itemCreated(_ element: AXUIElement) {
        queue.async { [weak self] in
            guard let self, self.isActive.withLock({ $0 }) else { return }
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            guard DockAXObserver.axString(element, kAXSubroleAttribute) == "AXMinimizedWindowDockItem",
                  let title = DockAXObserver.axString(element, kAXTitleAttribute)
            else { return }
            self.subject.send(title)
        }
    }
}
