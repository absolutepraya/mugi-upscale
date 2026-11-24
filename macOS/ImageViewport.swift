import CoreGraphics

enum PreviewZoom: Hashable {
    case fit, contain, actualPixels
}

struct ImageViewport {
    static let center = CGPoint(x: 0.5, y: 0.5)

    let size: CGSize
    let imageSize: CGSize
    let displayScale: CGFloat
    let zoom: PreviewZoom

    init(size: CGSize, pixels: CGSize, displayScale: CGFloat, zoom: PreviewZoom) {
        self.size = size
        self.displayScale = displayScale
        self.zoom = zoom

        let fitScale = min(size.width / pixels.width, size.height / pixels.height)
        let nativeScale = 1 / displayScale
        let scale = switch zoom {
        case .fit: fitScale
        case .contain: min(fitScale, nativeScale)
        case .actualPixels: nativeScale
        }
        imageSize = CGSize(width: pixels.width * scale, height: pixels.height * scale)
    }

    var canPan: Bool {
        zoom == .actualPixels && (imageSize.width > size.width || imageSize.height > size.height)
    }

    func panned(from center: CGPoint, by translation: CGSize) -> CGPoint {
        guard canPan else { return Self.center }
        let start = clamped(center)
        return clamped(CGPoint(x: start.x - translation.width / imageSize.width,
                               y: start.y - translation.height / imageSize.height))
    }

    func imageCenter(at center: CGPoint) -> CGPoint {
        let focus = clamped(center)
        let left = size.width / 2 - focus.x * imageSize.width
        let top = size.height / 2 - focus.y * imageSize.height
        return CGPoint(x: snap(left) + imageSize.width / 2,
                       y: snap(top) + imageSize.height / 2)
    }

    private func clamped(_ center: CGPoint) -> CGPoint {
        guard canPan else { return Self.center }
        let halfWidth = min(0.5, size.width / (2 * imageSize.width))
        let halfHeight = min(0.5, size.height / (2 * imageSize.height))
        return CGPoint(x: min(max(center.x, halfWidth), 1 - halfWidth),
                       y: min(max(center.y, halfHeight), 1 - halfHeight))
    }

    private func snap(_ point: CGFloat) -> CGFloat {
        zoom == .actualPixels ? (point * displayScale).rounded() / displayScale : point
    }
}
