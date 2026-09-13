import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RAPPShotCore

final class RenderingTests: XCTestCase {
    func testOpaqueRedactionIsFlatAndOutsidePixelsSurvive() throws {
        let original = try Fixtures.image(gradient: true)
        let rect = CGRect(x: 30, y: 20, width: 40, height: 30)
        let output = try ImageRenderer.redact(original, regions: [rect])
        for y in stride(from: 20, to: 50, by: 4) {
            for x in stride(from: 30, to: 70, by: 4) {
                XCTAssertEqual(try Fixtures.rgba(output, x: x, y: y), [0, 0, 0, 255])
            }
        }
        XCTAssertEqual(try Fixtures.rgba(original, x: 130, y: 130), try Fixtures.rgba(output, x: 130, y: 130))
    }

    func testManualRedactionCannotBecomeTransparentOrBeOverpainted() throws {
        var document = try ShotDocument(source: Fixtures.image(gradient: true))
        let rect = CGRect(x: 40, y: 50, width: 100, height: 80)
        try document.add(Annotation(kind: .redact, rect: rect,
                                    color: AnnotationColor(red: 1, green: 0, blue: 0, alpha: 0)))
        try document.add(Annotation(kind: .highlight, rect: rect, color: .white))
        let output = try ImageRenderer.render(document)
        XCTAssertEqual(try Fixtures.rgba(output, x: 90, y: 90), [0, 0, 0, 255])
    }

    func testNonzeroCropOffsetsRebaseBothArrowAxes() throws {
        let original = try Fixtures.image(gradient: true)
        var document = try ShotDocument(source: original)
        try document.setCrop(CGRect(x: 80, y: 50, width: 200, height: 150))
        try document.add(Annotation(kind: .arrow, rect: CGRect(x: 100, y: 70, width: 0, height: 0),
                                    end: CGPoint(x: 160, y: 100), color: .red, strokeWidth: 6))
        let image = try ImageRenderer.render(document)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 150)
        let endPixel = try Fixtures.rgba(image, x: 77, y: 49)
        XCTAssertGreaterThan(endPixel[0], 220)
        XCTAssertLessThan(endPixel[1], 100)
        XCTAssertEqual(try Fixtures.rgba(image, x: 170, y: 120),
                       try Fixtures.rgba(original, x: 250, y: 170))
    }

    func testCropAndOpaqueManualRegionUseOriginalPixelCoordinates() throws {
        var document = try ShotDocument(source: Fixtures.image(gradient: true))
        try document.add(Annotation(kind: .redact, rect: CGRect(x: 100, y: 90, width: 30, height: 30)))
        try document.setCrop(CGRect(x: 80, y: 50, width: 120, height: 140))
        let output = try ImageRenderer.render(document)
        XCTAssertEqual(try Fixtures.rgba(output, x: 25, y: 45), [0, 0, 0, 255])
        XCTAssertNotEqual(try Fixtures.rgba(output, x: 70, y: 100), [0, 0, 0, 255])
        try document.setCrop(nil)
        XCTAssertEqual(document.source.width, 320)
        XCTAssertEqual(try ImageRenderer.render(document).width, 320)
    }

    func testAllCosmeticAnnotationsRenderAndStayEditable() throws {
        var document = try ShotDocument(source: Fixtures.image(width: 800, height: 500, gradient: true))
        let text = Annotation(kind: .text, rect: CGRect(x: 20, y: 30, width: 240, height: 50), text: "fixture note")
        try document.add(text)
        try document.add(Annotation(kind: .box, rect: CGRect(x: 30, y: 120, width: 200, height: 80)))
        try document.add(Annotation(kind: .highlight, rect: CGRect(x: 30, y: 230, width: 250, height: 50)))
        try document.add(Annotation(kind: .pixelate, rect: CGRect(x: 400, y: 200, width: 100, height: 100)))
        let first = try ImageRenderer.render(document)
        var updated = text; updated.text = "edited fixture"
        try document.update(updated)
        let second = try ImageRenderer.render(document)
        XCTAssertNotEqual(try ImageRenderer.png(first), try ImageRenderer.png(second))
        document.remove(text.id)
        XCTAssertEqual(document.annotations.count, 3)
    }

    func testEXIFOrientationIsAppliedBeforeCoordinatesAreEstablished() throws {
        try Fixtures.workspace { directory in
            let url = directory.appendingPathComponent("rotated.jpg")
            let image = try Fixtures.image(width: 120, height: 80, gradient: true)
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let normalized = try ImageRenderer.load(url)
            XCTAssertEqual(normalized.width, 80)
            XCTAssertEqual(normalized.height, 120)
        }
    }

    func testMalformedImageAndAnnotationCannotSilentlyPass() throws {
        try Fixtures.workspace { directory in
            let url = directory.appendingPathComponent("broken.png")
            try Data("not an image".utf8).write(to: url)
            XCTAssertThrowsError(try ImageRenderer.load(url))
        }
        var document = try ShotDocument(source: Fixtures.image())
        XCTAssertThrowsError(try document.add(Annotation(kind: .box, rect: .zero)))
        XCTAssertThrowsError(try document.add(Annotation(kind: .redact, rect: CGRect(x: 800, y: 900, width: 20, height: 20))))
        XCTAssertThrowsError(try document.setCrop(CGRect(x: 800, y: 900, width: 10, height: 10)))
        XCTAssertEqual(document.annotations.count, 0)
        XCTAssertNil(document.crop)
    }
}
