import Cocoa

extension CGWindowID {
    public func title() -> String? {
        cgsWindowTitle(cgsMainConnection(), self)
    }

    public func level() -> Int32 {
        cgsWindowLevel(cgsMainConnection(), self)
    }

    public func spaces() -> [Int] {
        cgsWindowSpaces(cgsMainConnection(), self)
    }

    public func isAtNormalLevelOrAbove() -> Bool {
        let windowLevel = level()
        let normalLevel = CGWindowLevelForKey(.normalWindow)
        return windowLevel >= Int32(normalLevel)
    }
}

public extension AXValue {
    static func from(point: CGPoint) -> AXValue? {
        var point = point
        return AXValueCreate(.cgPoint, &point)
    }

    static func from(size: CGSize) -> AXValue? {
        var size = size
        return AXValueCreate(.cgSize, &size)
    }

    static func from(rect: CGRect) -> AXValue? {
        var rect = rect
        return AXValueCreate(.cgRect, &rect)
    }
}
