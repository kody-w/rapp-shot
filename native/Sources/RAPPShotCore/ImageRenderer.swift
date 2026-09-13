import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum ImageRenderer {
    public static func load(_ url: URL) throws -> CGImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ShotError.invalidImage
        }
        do { try PixelGeometry.validate(CGSize(width: width, height: height)) }
        catch { throw ShotError.invalidImage }
        // Honor EXIF orientation before establishing the editor's top-left pixel coordinate space.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShotError.invalidImage
        }
        return image
    }

    public static func png(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ShotError.exportFailed("PNG encoder unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotError.exportFailed("PNG encoding failed.") }
        return output as Data
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        try PixelGeometry.validate(CGSize(width: width, height: height))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShotError.exportFailed("Could not allocate the image renderer.")
        }
        return context
    }

    public static func render(_ document: ShotDocument) throws -> CGImage {
        let crop = document.visibleRect
        guard let base = document.source.cropping(to: crop) else { throw ShotError.invalidGeometry }
        let context = try context(width: base.width, height: base.height)
        let height = CGFloat(base.height)
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let cosmetic = document.annotations.filter { $0.kind != .redact }
        // Always composite opaque redactions last, never let a later cosmetic operation reveal them.
        for annotation in cosmetic + document.annotations.filter({ $0.kind == .redact }) {
            try annotation.validate()
            let top = annotation.rect.offsetBy(dx: -crop.minX, dy: -crop.minY)
            let rect = PixelGeometry.bottomLeft(top, imageHeight: height)
            context.saveGState()
            context.setStrokeColor(annotation.color.cgColor)
            context.setFillColor(annotation.color.cgColor)
            context.setLineWidth(annotation.strokeWidth)
            switch annotation.kind {
            case .box:
                context.stroke(rect)
            case .highlight:
                context.fill(rect)
            case .redact:
                let bounds = top.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
                if !bounds.isNull && !bounds.isEmpty {
                    opaqueFill(try PixelGeometry.clippedIntegral(bounds, in: CGSize(width: base.width, height: base.height)),
                               height: height, context: context)
                }
            case .arrow:
                let start = CGPoint(x: top.minX, y: height - top.minY)
                let end = CGPoint(x: annotation.end.x - crop.minX,
                                  y: height - (annotation.end.y - crop.minY))
                context.setLineCap(.round)
                context.move(to: start); context.addLine(to: end); context.strokePath()
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = max(12, annotation.strokeWidth * 4)
                context.move(to: end)
                context.addLine(to: CGPoint(x: end.x - head * cos(angle - .pi / 7),
                                           y: end.y - head * sin(angle - .pi / 7)))
                context.addLine(to: CGPoint(x: end.x - head * cos(angle + .pi / 7),
                                           y: end.y - head * sin(angle + .pi / 7)))
                context.closePath(); context.fillPath()
            case .text:
                let attributed = NSAttributedString(string: annotation.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String):
                        CTFontCreateWithName("Helvetica-Bold" as CFString, annotation.fontSize, nil),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                context.setFillColor(CGColor(gray: 0, alpha: 0.80))
                context.fill(CGRect(x: top.minX - 6, y: height - top.minY - annotation.fontSize - 5,
                                    width: width + 12, height: annotation.fontSize + 12))
                context.textPosition = CGPoint(x: top.minX, y: height - top.minY - annotation.fontSize)
                CTLineDraw(line, context)
            case .pixelate:
                let clipped = top.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
                if !clipped.isNull && !clipped.isEmpty {
                    let integral = try PixelGeometry.clippedIntegral(clipped, in: CGSize(width: base.width, height: base.height))
                    guard let snapshot = context.makeImage(), let piece = snapshot.cropping(to: integral),
                          let filter = CIFilter(name: "CIPixellate") else {
                        throw ShotError.exportFailed("Cosmetic pixelation could not render.")
                    }
                    filter.setValue(CIImage(cgImage: piece), forKey: kCIInputImageKey)
                    filter.setValue(18, forKey: kCIInputScaleKey)
                    guard let filtered = filter.outputImage,
                          let pixels = CIContext().createCGImage(filtered, from: CGRect(x: 0, y: 0, width: piece.width, height: piece.height)) else {
                        throw ShotError.exportFailed("Cosmetic pixelation could not render.")
                    }
                    context.draw(pixels, in: PixelGeometry.bottomLeft(integral, imageHeight: height))
                }
            }
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ShotError.exportFailed("Rendering failed.") }
        return image
    }

    private static func opaqueFill(_ topRect: CGRect, height: CGFloat, context: CGContext) {
        context.setBlendMode(.copy)
        context.setShouldAntialias(false)
        context.setAlpha(1)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(PixelGeometry.bottomLeft(topRect, imageHeight: height))
    }

    public static func redact(_ image: CGImage, regions: [CGRect]) throws -> CGImage {
        let context = try context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for region in regions {
            let clipped = try PixelGeometry.clippedIntegral(region, in: CGSize(width: image.width, height: image.height))
            opaqueFill(clipped, height: CGFloat(image.height), context: context)
        }
        guard let result = context.makeImage() else { throw ShotError.exportFailed("Redaction rendering failed.") }
        return result
    }
}
