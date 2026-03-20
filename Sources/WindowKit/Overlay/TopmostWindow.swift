import Cocoa

final class TopmostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = true
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: Int(Int32.max) - 2)
        canBecomeVisibleWithoutLogin = true
        ignoresMouseEvents = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }
}
