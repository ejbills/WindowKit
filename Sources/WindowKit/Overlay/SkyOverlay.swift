import Cocoa
import Combine
import SwiftUI

// MARK: - Overlay Anchor

/// Describes where the overlay content appears on screen.
public enum OverlayAnchor: Sendable {
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

/// Controls when the overlay is visible.
public enum OverlayVisibility: Sendable {
    /// Always visible while enabled — on top of everything including fullscreen apps.
    case always
    /// Only visible when the screen is locked.
    case lockScreenOnly
    /// Only visible when the screen is unlocked.
    case unlockedOnly
}

// MARK: - Overlay Manager

@MainActor
@Observable
public final class OverlayManager {
    public static let shared = OverlayManager()

    public private(set) var isEnabled: Bool = false
    public private(set) var isShowing: Bool = false

    private var overlayWindow: TopmostWindow?
    private var pinnedContent: AnyView?
    private var pinnedScreen: NSScreen?
    private var pinnedAnchor: OverlayAnchor = .center
    private var visibility: OverlayVisibility = .always
    private var lastWindowFrame: NSRect?
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = ScreenLockObserver.shared.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reevaluate()
            }
    }

    public func show<V: View>(
        _ content: V,
        anchor: OverlayAnchor = .center,
        visibility: OverlayVisibility = .always,
        on screen: NSScreen? = nil
    ) {
        tearDown()

        pinnedContent = AnyView(content)
        pinnedScreen = screen ?? NSScreen.main
        pinnedAnchor = anchor
        self.visibility = visibility
        isEnabled = true
        Logger.info("Overlay: enabled (\(visibility))")

        reevaluate()
    }

    public func hide() {
        tearDown()
        Logger.info("Overlay: disabled")
    }

    private func tearDown() {
        dismissWindow()
        pinnedContent = nil
        pinnedScreen = nil
        lastWindowFrame = nil
        isEnabled = false
    }

    private func reevaluate() {
        guard isEnabled else { return }

        let locked = ScreenLockObserver.shared.isLocked
        let shouldShow: Bool = switch visibility {
        case .always: true
        case .lockScreenOnly: locked
        case .unlockedOnly: !locked
        }

        if shouldShow {
            presentWindow()
        } else {
            dismissWindow()
        }
    }

    private func presentWindow() {
        guard let content = pinnedContent, overlayWindow == nil else { return }

        let screen = pinnedScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let hostingView = NSHostingView(rootView: content)
        let fittingSize = hostingView.fittingSize
        let contentSize = NSSize(
            width: max(fittingSize.width, 1),
            height: max(fittingSize.height, 1)
        )

        let windowRect: NSRect
        if let saved = lastWindowFrame {
            // Restore the user's dragged position, keep the saved size
            windowRect = saved
        } else {
            windowRect = resolveFrame(
                anchor: pinnedAnchor,
                contentSize: contentSize,
                screen: screen
            )
        }

        let window = TopmostWindow(contentRect: windowRect)
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)
        window.contentView = hostingView

        if visibility == .lockScreenOnly {
            window.isMovable = false
            window.isMovableByWindowBackground = false
        }

        window.orderFrontRegardless()

        SkyLightSpaceOperator.shared.addWindow(CGWindowID(window.windowNumber))

        overlayWindow = window
        isShowing = true
        Logger.info("Overlay: window shown")
    }

    private func dismissWindow() {
        if let window = overlayWindow {
            lastWindowFrame = window.frame
            window.contentView = nil
            window.orderOut(nil)
        }
        overlayWindow = nil
        isShowing = false
    }

    private func resolveFrame(
        anchor: OverlayAnchor,
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

public extension View {
    /// Presents an overlay above everything — fullscreen apps, Dock, even the lock screen.
    ///
    /// - Parameters:
    ///   - isEnabled: Binding that controls whether the overlay is active.
    ///   - anchor: Where on screen to place the content.
    ///   - visibility: When the overlay should be visible (always, lock screen only, unlocked only).
    ///   - screen: Which screen to show on. Defaults to main screen.
    ///   - content: The view to display in the overlay.
    func skyOverlay<V: View>(
        isEnabled: Binding<Bool>,
        anchor: OverlayAnchor = .center,
        visibility: OverlayVisibility = .always,
        on screen: NSScreen? = nil,
        @ViewBuilder content: () -> V
    ) -> some View {
        modifier(SkyOverlayModifier(
            isEnabled: isEnabled,
            anchor: anchor,
            visibility: visibility,
            screen: screen,
            overlayContent: content()
        ))
    }

    /// Presents this view as an overlay above everything.
    func skyOverlay(
        isEnabled: Binding<Bool>,
        anchor: OverlayAnchor = .center,
        visibility: OverlayVisibility = .always,
        on screen: NSScreen? = nil
    ) -> some View {
        modifier(SkyOverlayModifier(
            isEnabled: isEnabled,
            anchor: anchor,
            visibility: visibility,
            screen: screen,
            overlayContent: self
        ))
    }
}

private struct SkyOverlayModifier<OverlayContent: View>: ViewModifier {
    @Binding var isEnabled: Bool
    let anchor: OverlayAnchor
    let visibility: OverlayVisibility
    let screen: NSScreen?
    let overlayContent: OverlayContent

    func body(content: Content) -> some View {
        content
            .onChange(of: isEnabled) { _, enabled in
                if enabled {
                    OverlayManager.shared.show(
                        overlayContent, anchor: anchor, visibility: visibility, on: screen
                    )
                } else {
                    OverlayManager.shared.hide()
                }
            }
            .onAppear {
                if isEnabled {
                    OverlayManager.shared.show(
                        overlayContent, anchor: anchor, visibility: visibility, on: screen
                    )
                }
            }
            .onDisappear {
                OverlayManager.shared.hide()
            }
    }
}
