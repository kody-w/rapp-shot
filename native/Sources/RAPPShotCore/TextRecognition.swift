import Foundation
import Vision
import CoreGraphics

public struct OCRLine: Equatable, Sendable {
    public let text: String
    public let rect: CGRect
    public let confidence: Float
    public init(text: String, rect: CGRect, confidence: Float = 1) {
        self.text = text; self.rect = rect; self.confidence = confidence
    }
}

public struct OCRResult: Equatable, Sendable {
    public let lines: [OCRLine]
    public let imageSize: CGSize
    public init(lines: [OCRLine], imageSize: CGSize) { self.lines = lines; self.imageSize = imageSize }
    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public protocol TextRecognizing {
    func recognize(_ image: CGImage) throws -> OCRResult
}

public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(_ image: CGImage) throws -> OCRResult {
        let size = CGSize(width: image.width, height: image.height)
        try PixelGeometry.validate(size)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { throw ShotError.recognitionFailed(error.localizedDescription) }
        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first else { continue }
            let rect = try PixelGeometry.visionRect(observation.boundingBox, imageSize: size)
            lines.append(OCRLine(text: top.string, rect: rect, confidence: top.confidence))
        }
        return OCRResult(lines: lines, imageSize: size)
    }
}
