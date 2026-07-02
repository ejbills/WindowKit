import Cocoa

/// Conversions between AppKit screen coordinates (origin at the primary
/// display's bottom-left corner, y-up) and the AX/CGS coordinate space used by
/// window bounds and manipulation APIs such as `CapturedWindow.setPosition`
/// (origin at the primary display's top-left corner, y-down).
public enum ScreenCoordinates {
    public static func axPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight() - point.y)
    }

    public static func axRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight() - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func appKitPoint(fromAX point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight() - point.y)
    }

    public static func appKitRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryScreenHeight() - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func primaryScreenHeight() -> CGFloat {
        let screens = NSScreen.screens
        if let primary = screens.first(where: { $0.directDisplayID == CGMainDisplayID() }) {
            return primary.frame.height
        }
        if let originScreen = screens.first(where: { $0.frame.origin == .zero }) {
            return originScreen.frame.height
        }
        return screens.first?.frame.height ?? 0
    }
}
