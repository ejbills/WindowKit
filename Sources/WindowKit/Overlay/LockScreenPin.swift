import Cocoa
import Combine
import SwiftUI

// MARK: - Lock Screen Anchor

/// Describes where the pinned content appears on the lock screen.
public enum LockScreenAnchor: Sendable {
    /// Centered on screen.
    case center
    /// Centered horizontally, offset vertically from center (positive = up).
    case aboveCenter(offset: CGFloat = 160)
    /// Fixed origin in screen coordinates.
    case origin(x: CGFloat, y: CGFloat)
    /// Alignment-based positioning with optional padding from screen edges.
    case aligned(horizontal: HorizontalAlignment, vertical: VerticalAlignment, padding: CGFloat = 20)
    /// Client provides the full frame in screen coordinates.
    case frame(NSRect)
}

// MARK: - Lock Screen Pin Manager

@MainActor
@Observable
public final class LockScreenPinManager {
    public static let shared = LockScreenPinManager()

    public private(set) var isPinned: Bool = false
    public private(set) var isShowingOnLockScreen: Bool = false

    private var overlayWindow: TopmostWindow?
    private var pinnedContent: AnyView?
    private var pinnedScreen: NSScreen?
    private var pinnedAnchor: LockScreenAnchor = .center
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = ScreenLockObserver.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                self?.handleLockStateChanged(locked)
            }
    }

    public func pin<V: View>(
        _ content: V,
        anchor: LockScreenAnchor = .center,
        on screen: NSScreen? = nil
    ) {
        unpinIfNeeded()

        pinnedContent = AnyView(content)
        pinnedScreen = screen ?? NSScreen.main
        pinnedAnchor = anchor
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

    public func toggle<V: View>(
        _ content: V,
        anchor: LockScreenAnchor = .center,
        on screen: NSScreen? = nil
    ) {
        if isPinned {
            unpin()
        } else {
            pin(content, anchor: anchor, on: screen)
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

        let hostingView = NSHostingView(rootView: content)
        let fittingSize = hostingView.fittingSize
        let contentSize = NSSize(
            width: max(fittingSize.width, 1),
            height: max(fittingSize.height, 1)
        )
        let windowRect = resolveFrame(
            anchor: pinnedAnchor,
            contentSize: contentSize,
            screen: screen
        )

        let window = TopmostWindow(contentRect: windowRect)
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)
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

    private func resolveFrame(
        anchor: LockScreenAnchor,
        contentSize: NSSize,
        screen: NSScreen
    ) -> NSRect {
        let sf = screen.frame
        let w = contentSize.width
        let h = contentSize.height

        switch anchor {
        case .center:
            return NSRect(x: sf.midX - w / 2, y: sf.midY - h / 2, width: w, height: h)

        case .aboveCenter(let offset):
            return NSRect(x: sf.midX - w / 2, y: sf.midY + offset - h / 2, width: w, height: h)

        case .origin(let x, let y):
            return NSRect(x: sf.origin.x + x, y: sf.origin.y + y, width: w, height: h)

        case .aligned(let horiz, let vert, let padding):
            let x: CGFloat = switch horiz {
            case .leading: sf.minX + padding
            case .trailing: sf.maxX - w - padding
            default: sf.midX - w / 2
            }
            let y: CGFloat = switch vert {
            case .top: sf.maxY - h - padding
            case .bottom: sf.minY + padding
            default: sf.midY - h / 2
            }
            return NSRect(x: x, y: y, width: w, height: h)

        case .frame(let rect):
            return rect
        }
    }
}

// MARK: - SwiftUI View Modifier

struct LockScreenPinModifier<PinnedContent: View>: ViewModifier {
    let pinnedContent: PinnedContent
    let anchor: LockScreenAnchor
    let label: String

    @State private var isPinned = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    isPinned.toggle()
                    if isPinned {
                        LockScreenPinManager.shared.pin(pinnedContent, anchor: anchor)
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
    func pinnableToLockScreen(
        anchor: LockScreenAnchor = .center,
        label: String = "Pin to Lock Screen"
    ) -> some View {
        modifier(LockScreenPinModifier(pinnedContent: self, anchor: anchor, label: label))
    }

    /// Adds a right-click context menu option to pin custom content to the lock screen.
    func pinnableToLockScreen<V: View>(
        anchor: LockScreenAnchor = .center,
        label: String = "Pin to Lock Screen",
        @ViewBuilder content: () -> V
    ) -> some View {
        modifier(LockScreenPinModifier(pinnedContent: content(), anchor: anchor, label: label))
    }
}
