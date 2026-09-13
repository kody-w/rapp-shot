import Foundation
import CoreGraphics

public enum PixelGeometry {
    public static let maximumPixels = 100_000_000

    public static func validate(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= 32_768, size.height <= 32_768,
              size.width * size.height <= CGFloat(maximumPixels) else {
            throw ShotError.invalidGeometry
        }
    }

    public static func clippedIntegral(_ rect: CGRect, in size: CGSize) throws -> CGRect {
        try validate(size)
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { throw ShotError.invalidGeometry }
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            throw ShotError.invalidGeometry
        }
        return clipped.integral.intersection(CGRect(origin: .zero, size: size))
    }

    public static func visionRect(_ normalized: CGRect, imageSize: CGSize) throws -> CGRect {
        let rect = CGRect(
            x: normalized.minX * imageSize.width,
            y: (1 - normalized.maxY) * imageSize.height,
            width: normalized.width * imageSize.width,
            height: normalized.height * imageSize.height
        )
        return try clippedIntegral(rect, in: imageSize)
    }

    public static func capturePixels(points: CGSize, scale: CGFloat) throws -> CGSize {
        guard scale.isFinite, scale > 0 else { throw ShotError.invalidGeometry }
        let result = CGSize(width: (points.width * scale).rounded(.up),
                            height: (points.height * scale).rounded(.up))
        try validate(result)
        return result
    }

    public static func bottomLeft(_ topLeft: CGRect, imageHeight: CGFloat) -> CGRect {
        CGRect(x: topLeft.minX, y: imageHeight - topLeft.maxY,
               width: topLeft.width, height: topLeft.height)
    }

    public static func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

public struct ViewportTransform {
    public let imageSize: CGSize
    public let contentRect: CGRect
    public let scale: CGFloat

    public init(imageSize: CGSize, viewport: CGSize) throws {
        try PixelGeometry.validate(imageSize)
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { throw ShotError.invalidGeometry }
        self.imageSize = imageSize
        scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        contentRect = CGRect(x: (viewport.width - shown.width) / 2,
                             y: (viewport.height - shown.height) / 2,
                             width: shown.width, height: shown.height)
    }

    public func imagePoint(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard clamp || contentRect.contains(point) else { return nil }
        return CGPoint(x: min(imageSize.width, max(0, (point.x - contentRect.minX) / scale)),
                       y: min(imageSize.height, max(0, (point.y - contentRect.minY) / scale)))
    }

    public func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + point.x * scale, y: contentRect.minY + point.y * scale)
    }

    public func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: viewPoint(rect.origin),
               size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }
}
