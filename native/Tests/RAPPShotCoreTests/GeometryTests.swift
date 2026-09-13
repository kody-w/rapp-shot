import XCTest
@testable import RAPPShotCore

final class GeometryTests: XCTestCase {
    func testVisionTopLeftConversionAtRetinaResolution() throws {
        let rect = try PixelGeometry.visionRect(CGRect(x: 0.2, y: 0.6, width: 0.25, height: 0.15),
                                                imageSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(rect.minX, 400, accuracy: 1)
        XCTAssertEqual(rect.minY, 250, accuracy: 1)
        XCTAssertEqual(rect.width, 500, accuracy: 1)
        XCTAssertEqual(rect.height, 150, accuracy: 1)
    }

    func testOutwardIntegralClippingNeverLosesGlyphEdges() throws {
        let rect = try PixelGeometry.clippedIntegral(CGRect(x: -2.4, y: 3.2, width: 9.8, height: 4.2),
                                                     in: CGSize(width: 100, height: 80))
        XCTAssertEqual(rect, CGRect(x: 0, y: 3, width: 8, height: 5))
    }

    func testLetterboxViewportRoundTripsAndRejectsMargins() throws {
        let transform = try ViewportTransform(imageSize: CGSize(width: 4000, height: 2000),
                                              viewport: CGSize(width: 1000, height: 800))
        XCTAssertEqual(transform.contentRect, CGRect(x: 0, y: 150, width: 1000, height: 500))
        XCTAssertNil(transform.imagePoint(CGPoint(x: 40, y: 20)))
        XCTAssertEqual(transform.imagePoint(CGPoint(x: -40, y: 20), clamp: true), .zero)
        let source = CGPoint(x: 1378, y: 723)
        let result = try XCTUnwrap(transform.imagePoint(transform.viewPoint(source)))
        XCTAssertEqual(result.x, source.x, accuracy: 0.0001)
        XCTAssertEqual(result.y, source.y, accuracy: 0.0001)
    }

    func testRetinaAndFractionalDisplayScale() throws {
        XCTAssertEqual(try PixelGeometry.capturePixels(points: CGSize(width: 501, height: 399), scale: 2),
                       CGSize(width: 1002, height: 798))
        XCTAssertEqual(try PixelGeometry.capturePixels(points: CGSize(width: 301, height: 201), scale: 1.5),
                       CGSize(width: 452, height: 302))
    }

    func testReverseDragsAndBottomLeftRenderSpace() {
        let rect = PixelGeometry.rectangle(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 30, y: 20))
        XCTAssertEqual(rect, CGRect(x: 30, y: 20, width: 60, height: 50))
        XCTAssertEqual(PixelGeometry.bottomLeft(rect, imageHeight: 200),
                       CGRect(x: 30, y: 130, width: 60, height: 50))
    }

    func testInvalidGeometryIsRejectedRatherThanCapturingFallbackArea() {
        let size = CGSize(width: 500, height: 400)
        for rect in [CGRect(x: 700, y: 0, width: 10, height: 10),
                     CGRect(x: 0, y: 0, width: -4, height: 10),
                     CGRect(x: 0, y: 0, width: 0, height: 10),
                     CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            XCTAssertThrowsError(try PixelGeometry.clippedIntegral(rect, in: size))
        }
        XCTAssertThrowsError(try PixelGeometry.capturePixels(points: size, scale: 0))
        XCTAssertThrowsError(try PixelGeometry.validate(CGSize(width: 16_000, height: 16_000)))
        XCTAssertThrowsError(try ViewportTransform(imageSize: size, viewport: .zero))
    }
}
