import CoreGraphics

public enum WindowFillArea: Sendable {
    case full
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter

    func frame(in bounds: CGRect) -> CGRect {
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2

        switch self {
        case .full:
            return bounds
        case .leftHalf:
            return CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: bounds.height)
        case .rightHalf:
            return CGRect(x: bounds.midX, y: bounds.minY, width: halfWidth, height: bounds.height)
        case .topHalf:
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: halfHeight)
        case .topLeftQuarter:
            return CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: bounds.midX, y: bounds.minY, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: bounds.minX, y: bounds.midY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: bounds.midX, y: bounds.midY, width: halfWidth, height: halfHeight)
        }
    }
}
