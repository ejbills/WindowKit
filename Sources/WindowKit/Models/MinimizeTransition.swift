import CoreGraphics

/// A window starting to minimize or restore, announced on `WindowKit.minimizeTransitions`.
///
/// A minimize WindowKit performs can be announced twice. It is first announced with `showsNativeAnimation`
/// false before WindowKit hides the owner app; if the app can't be hidden or the window doesn't minimize while
/// it is, the same window is announced again with `showsNativeAnimation` true, and WindowKit minimizes it
/// normally `coverLeadTime` later. A host already animating the window should then cover the native animation
/// instead of starting another. The Dock tile of either attempt is never announced.
public struct MinimizeTransition: @unchecked Sendable {
    public enum Kind: Sendable {
        case minimize
        case restore
    }

    public let kind: Kind
    /// The window as cached when the transition began.
    public let window: CapturedWindow
    /// A full-resolution capture of the window taken for this transition only and never cached. Set for
    /// the transitions WindowKit performs itself (a restore's is nil if the capture failed); nil for
    /// minimizes started elsewhere, whose window is already warping when they are announced.
    public let image: CGImage?
    /// Whether the native Dock animation plays too. False only for the first announcement of a minimize
    /// WindowKit performs itself, which runs with the owner app hidden.
    public let showsNativeAnimation: Bool
    /// Whether WindowKit performs the transition itself. Its native animation, when it plays, starts
    /// `coverLeadTime` after the announcement; a minimize started elsewhere is announced ~30ms before its
    /// native animation shows.
    public let isPerformedByWindowKit: Bool
}
