import CoreGraphics

/// A window starting to minimize or restore, announced on `WindowKit.minimizeTransitions`.
public struct MinimizeTransition: @unchecked Sendable {
    public enum Kind: Sendable {
        case minimize
        case restore
    }

    public let kind: Kind
    /// The window as cached when the transition began.
    public let window: CapturedWindow
    /// A full-resolution capture of the window taken for this transition only and never cached. Set for
    /// the transitions WindowKit performs itself; nil for minimizes started elsewhere, whose window is
    /// already warping when they are announced.
    public let image: CGImage?
    /// Whether the native Dock animation plays too. False only for minimizes WindowKit performs itself
    /// while tracking transitions, which run with the owner app hidden.
    public let showsNativeAnimation: Bool
}
