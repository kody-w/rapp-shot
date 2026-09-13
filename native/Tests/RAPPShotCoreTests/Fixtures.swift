import XCTest
import AppKit
import CoreGraphics
import CoreText
@testable import RAPPShotCore

enum Fixtures {
    static func image(width: Int = 320, height: Int = 240, gradient: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        if gradient {
            for y in 0..<height {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    pixels[index] = UInt8(x % 255)
                    pixels[index + 1] = UInt8(y % 255)
                    pixels[index + 2] = UInt8((x + y) % 255)
                }
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ShotError.invalidImage
        }
        return image
    }

    static func textImage(_ lines: [String], width: Int = 1500) throws -> CGImage {
        let height = 80 + lines.count * 70
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShotError.invalidImage
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 28, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 35, y: height - 65 - index * 70)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        guard let image = context.makeImage() else { throw ShotError.invalidImage }
        return image
    }

    static func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ShotError.invalidImage
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { throw ShotError.invalidImage }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 4))
    }

    static func workspace(_ body: (URL) throws -> Void) throws {
        let native = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = native.appendingPathComponent(".test-artifacts/unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove owned fixture directory: \(error)") }
        }
        try body(directory)
    }
}

final class SequenceRecognizer: TextRecognizing {
    var responses: [Result<OCRResult, Error>]
    private(set) var calls = 0
    init(_ responses: [Result<OCRResult, Error>]) { self.responses = responses }
    func recognize(_ image: CGImage) throws -> OCRResult {
        guard calls < responses.count else { throw ShotError.recognitionFailed("Unexpected fixture OCR call") }
        defer { calls += 1 }
        return try responses[calls].get()
    }
}
