import Foundation
import CoreGraphics

public struct AnnotationColor: Equatable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let red = AnnotationColor(red: 1, green: 0.23, blue: 0.19)
    public static let yellow = AnnotationColor(red: 1, green: 0.9, blue: 0, alpha: 0.4)
    public static let white = AnnotationColor(red: 1, green: 1, blue: 1)
    public static let black = AnnotationColor(red: 0, green: 0, blue: 0)
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case box, arrow, text, highlight, redact, pixelate
        public var id: String { rawValue }
        public var title: String { self == .pixelate ? "Pixelate (cosmetic)" : rawValue.capitalized }
    }
    public let id: UUID
    public var kind: Kind
    public var rect: CGRect
    public var end: CGPoint
    public var text: String
    public var color: AnnotationColor
    public var strokeWidth: CGFloat
    public var fontSize: CGFloat

    public init(id: UUID = UUID(), kind: Kind, rect: CGRect, end: CGPoint? = nil,
                text: String = "", color: AnnotationColor? = nil,
                strokeWidth: CGFloat = 4, fontSize: CGFloat = 28) {
        self.id = id; self.kind = kind; self.rect = rect
        self.end = end ?? CGPoint(x: rect.maxX, y: rect.maxY)
        self.text = text
        self.color = color ?? (kind == .highlight ? .yellow : kind == .text ? .white : .red)
        self.strokeWidth = strokeWidth; self.fontSize = fontSize
    }

    public func validate() throws {
        let numbers = [rect.minX, rect.minY, rect.width, rect.height, end.x, end.y,
                       strokeWidth, fontSize, color.red, color.green, color.blue, color.alpha]
        guard numbers.allSatisfy(\.isFinite), rect.width >= 0, rect.height >= 0,
              (0.5...64).contains(strokeWidth), (6...180).contains(fontSize),
              [color.red, color.green, color.blue, color.alpha].allSatisfy({ (0...1).contains($0) }),
              text.count <= 4_096 else { throw ShotError.invalidGeometry }
        if kind != .arrow && kind != .text && (rect.width < 1 || rect.height < 1) {
            throw ShotError.invalidGeometry
        }
    }
}

public struct ShotDocument {
    public let id: UUID
    public let source: CGImage
    public let sourceURL: URL?
    public private(set) var crop: CGRect?
    public private(set) var annotations: [Annotation]
    public private(set) var revision: Int
    public private(set) var editID: UUID

    public init(source: CGImage, sourceURL: URL? = nil) throws {
        try PixelGeometry.validate(CGSize(width: source.width, height: source.height))
        id = UUID(); editID = UUID()
        self.source = source; self.sourceURL = sourceURL
        annotations = []; revision = 0
    }
    public var sourceSize: CGSize { CGSize(width: source.width, height: source.height) }
    public var visibleRect: CGRect { crop ?? CGRect(origin: .zero, size: sourceSize) }

    public mutating func setCrop(_ rect: CGRect?) throws {
        crop = try rect.map { try PixelGeometry.clippedIntegral($0, in: sourceSize) }
        revision += 1; editID = UUID()
    }

    public mutating func add(_ annotation: Annotation) throws {
        try validateAnnotation(annotation)
        guard annotations.count < 1_000 else { throw ShotError.invalidAction("Too many annotations.") }
        annotations.append(annotation); revision += 1; editID = UUID()
    }

    public mutating func update(_ annotation: Annotation) throws {
        try validateAnnotation(annotation)
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else {
            throw ShotError.invalidAction("The selected annotation no longer exists.")
        }
        annotations[index] = annotation; revision += 1; editID = UUID()
    }

    public mutating func remove(_ id: UUID) {
        annotations.removeAll { $0.id == id }; revision += 1; editID = UUID()
    }

    private func validateAnnotation(_ annotation: Annotation) throws {
        try annotation.validate()
        if annotation.kind == .redact {
            _ = try PixelGeometry.clippedIntegral(annotation.rect, in: sourceSize)
        }
    }
}
