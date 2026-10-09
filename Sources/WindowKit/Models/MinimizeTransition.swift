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
    /// the transitions WindowKit performs itself (nil if the capture failed); nil for minimizes started
    /// elsewhere, whose window is already warping when they are announced.
    public let image: CGImage?
    /// Whether WindowKit performs the transition itself. Its native animation starts `coverLeadTime` after the
    /// announcement; a minimize started elsewhere is announced ~30ms before its native animation shows.
    public let isPerformedByWindowKit: Bool
}
