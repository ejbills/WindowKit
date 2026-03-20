import Cocoa
import Combine
import SwiftUI

// MARK: - Lock Screen Pin Manager

@MainActor
@Observable
public final class LockScreenPinManager {
    public static let shared = LockScreenPinManager()

    public private(set) var isPinned: Bool = false
    public private(set) var isShowingOnLockScreen: Bool = false

    private var overlayWindow: TopmostWindow?
    private var overlayController: NSWindowController?
    private var pinnedContent: AnyView?
    private var pinnedScreen: NSScreen?
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = ScreenLockObserver.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                self?.handleLockStateChanged(locked)
            }
    }

    public func pin<V: View>(_ content: V, on screen: NSScreen? = nil) {
        unpinIfNeeded()

        pinnedContent = AnyView(content)
        pinnedScreen = screen ?? NSScreen.main
        isPinned = true
        Logger.info("LockScreenPin: pinned content")

        if ScreenLockObserver.shared.isLocked {
            showOverlay()
        }
    }

    public func unpin() {
        unpinIfNeeded()
        Logger.info("LockScreenPin: unpinned content")
    }

    public func toggle<V: View>(_ content: V, on screen: NSScreen? = nil) {
        if isPinned {
            unpin()
        } else {
            pin(content, on: screen)
        }
    }

    private func unpinIfNeeded() {
        hideOverlay()
        pinnedContent = nil
        pinnedScreen = nil
        isPinned = false
    }

    private func handleLockStateChanged(_ locked: Bool) {
        guard isPinned else { return }

        if locked {
            showOverlay()
        } else {
            hideOverlay()
        }
    }

    private func showOverlay() {
        guard let content = pinnedContent, overlayWindow == nil else { return }

        let screen = pinnedScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let window = TopmostWindow(contentRect: screen.frame)
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        window.contentView = hostingView
        window.orderFrontRegardless()

        SkyLightSpaceOperator.shared.addWindow(CGWindowID(window.windowNumber))

        overlayWindow = window
        isShowingOnLockScreen = true
        Logger.info("LockScreenPin: overlay shown on lock screen")
    }

    private func hideOverlay() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        isShowingOnLockScreen = false
    }
}

// MARK: - SwiftUI View Modifier

struct LockScreenPinModifier<PinnedContent: View>: ViewModifier {
    let pinnedContent: PinnedContent
    let label: String

    @State private var isPinned = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    isPinned.toggle()
                    if isPinned {
                        LockScreenPinManager.shared.pin(pinnedContent)
                    } else {
                        LockScreenPinManager.shared.unpin()
                    }
                } label: {
                    if isPinned {
                        Label("Unpin from Lock Screen", systemImage: "pin.slash")
                    } else {
                        Label(label, systemImage: "pin")
                    }
                }
            }
            .onDisappear {
                if isPinned {
                    LockScreenPinManager.shared.unpin()
                    isPinned = false
                }
            }
    }
}

// MARK: - View Extension

public extension View {
    /// Adds a right-click context menu option to pin this view to the lock screen.
    ///
    /// When pinned and the screen locks, the view is displayed in a topmost overlay
    /// window above the lock screen. When the screen unlocks, the overlay is hidden.
    ///
    /// - Parameters:
    ///   - label: The context menu label. Defaults to "Pin to Lock Screen".
    ///   - content: The view to display on the lock screen. Defaults to `self`.
    func pinnableToLockScreen(
        label: String = "Pin to Lock Screen"
    ) -> some View {
        modifier(LockScreenPinModifier(pinnedContent: self, label: label))
    }

    /// Adds a right-click context menu option to pin custom content to the lock screen.
    ///
    /// - Parameters:
    ///   - label: The context menu label. Defaults to "Pin to Lock Screen".
    ///   - content: A closure returning the view to display on the lock screen.
    func pinnableToLockScreen<V: View>(
        label: String = "Pin to Lock Screen",
        @ViewBuilder content: () -> V
    ) -> some View {
        modifier(LockScreenPinModifier(pinnedContent: content(), label: label))
    }
}
