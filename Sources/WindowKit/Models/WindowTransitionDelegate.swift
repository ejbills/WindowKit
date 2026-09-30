import Foundation

/// Told about the minimizes and restores WindowKit performs (`minimizeWindow`, `restoreWindow`,
/// `toggleMinimizeWindow`, and `focusWindow` on a minimized window), so a host can animate them.
/// Minimizes started outside WindowKit arrive on `WindowKit.minimizeStarts` instead.
@MainActor
public protocol WindowTransitionDelegate: AnyObject {
    /// Called before WindowKit minimizes `window`; the minimize starts once this returns.
    func windowWillMinimize(_ window: CapturedWindow) async
    /// Called once the minimize request has finished, whether or not it succeeded.
    func windowDidMinimize(_ window: CapturedWindow)
    /// Called before WindowKit restores the minimized `window`; the restore starts once this returns.
    func windowWillRestore(_ window: CapturedWindow) async
    /// Called once the restore request has finished, whether or not it succeeded.
    func windowDidRestore(_ window: CapturedWindow)
}
