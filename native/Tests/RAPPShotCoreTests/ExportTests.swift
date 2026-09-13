import XCTest
import ImageIO
@testable import RAPPShotCore

final class ExportTests: XCTestCase {
    private func response(_ text: String = "fixture.user@example.test", rect: CGRect = CGRect(x: 30, y: 30, width: 200, height: 20)) -> OCRResult {
        OCRResult(lines: text.isEmpty ? [] : [OCRLine(text: text, rect: rect)], imageSize: CGSize(width: 320, height: 240))
    }

    private func prepared(_ document: ShotDocument, policy: ExportPolicy = .redacted) throws -> PreparedExport {
        let recognizer = SequenceRecognizer([.success(response()), .success(response(""))])
        return try ExportPipeline.prepare(document, policy: policy, detector: CredentialDetector(), recognizer: recognizer)
    }

    func testEveryDetectedLineIsPaddedAndOpaqueInActualPNG() throws {
        let document = try ShotDocument(source: Fixtures.image(gradient: true))
        let preview = try prepared(document)
        XCTAssertEqual(preview.automaticRegions, [CGRect(x: 27, y: 27, width: 206, height: 26)])
        XCTAssertTrue(preview.text.isEmpty)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.pngData as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try Fixtures.rgba(decoded, x: 28, y: 28), [0, 0, 0, 255])
        XCTAssertEqual(try Fixtures.rgba(decoded, x: 200, y: 50), [0, 0, 0, 255])
        XCTAssertNotEqual(preview.pngData, try ImageRenderer.png(document.source))
    }

    func testZeroLinesBlocksAutomaticButNotExplicitEditedPreview() throws {
        let document = try ShotDocument(source: Fixtures.image())
        XCTAssertThrowsError(try ExportPipeline.prepare(document, policy: .redacted, detector: CredentialDetector(),
            recognizer: SequenceRecognizer([.success(response(""))]))) {
            XCTAssertEqual($0 as? ShotError, .noRecognizedText)
        }

        let edited = try ExportPipeline.prepare(document, policy: .edited, detector: CredentialDetector(),
            recognizer: SequenceRecognizer([.success(response(""))]))
        XCTAssertEqual(edited.policy, .edited)
        XCTAssertTrue(edited.summary.contains("OFF"))
    }

    func testRedactionsOutsideTheCropAreNotReportedAsPainted() throws {
        var document = try ShotDocument(source: Fixtures.image())
        try document.add(Annotation(kind: .redact, rect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        try document.setCrop(CGRect(x: 100, y: 100, width: 100, height: 100))
        let preview = try ExportPipeline.prepare(document, policy: .edited, detector: CredentialDetector(),
            recognizer: SequenceRecognizer([.success(response(""))]))
        XCTAssertEqual(preview.manualRedactions, 0)
    }

    func testOCRFailureOnEitherPassBlocksAllOutput() throws {
        let document = try ShotDocument(source: Fixtures.image())
        let failure = ShotError.recognitionFailed("synthetic OCR failure")
        for responses: [Result<OCRResult, Error>] in [
            [.failure(failure)],
            [.success(response()), .failure(failure)]
        ] {
            XCTAssertThrowsError(try ExportPipeline.prepare(document, policy: .redacted, detector: CredentialDetector(),
                recognizer: SequenceRecognizer(responses))) {
                XCTAssertEqual($0 as? ShotError, failure)
            }
        }
    }

    func testSurvivingOrNewlyDetectedCredentialNeverProducesPreview() throws {
        let document = try ShotDocument(source: Fixtures.image())
        for after in [response(), response("different.user@example.test")] {
            XCTAssertThrowsError(try ExportPipeline.prepare(document, policy: .redacted, detector: CredentialDetector(),
                recognizer: SequenceRecognizer([.success(response()), .success(after)]))) {
                guard case ShotError.verificationFailed = $0 else { return XCTFail("Wrong error \($0)") }
            }
        }
    }

    func testNoMatchesDoesNotSkipVerificationOrClaimAllClear() throws {
        let document = try ShotDocument(source: Fixtures.image())
        let input = response("ordinary fixture prose")
        let recognizer = SequenceRecognizer([.success(input), .success(input)])
        let preview = try ExportPipeline.prepare(document, policy: .redacted,
                                                 detector: CredentialDetector(), recognizer: recognizer)
        XCTAssertEqual(recognizer.calls, 2)
        XCTAssertTrue(preview.automaticRegions.isEmpty)
        XCTAssertTrue(preview.summary.contains("not that the image contains no secrets"))
    }

    func testUnreviewedStalePolicyAndDifferentImageCannotExport() throws {
        var document = try ShotDocument(source: Fixtures.image())
        let preview = try prepared(document)
        XCTAssertThrowsError(try ExportPipeline.authorize(preview, document: document, policy: .redacted, reviewed: false)) {
            XCTAssertEqual($0 as? ShotError, .previewNotReviewed)
        }
        XCTAssertThrowsError(try ExportPipeline.authorize(preview, document: document, policy: .edited, reviewed: true))
        let other = try ShotDocument(source: Fixtures.image())
        XCTAssertThrowsError(try ExportPipeline.authorize(preview, document: other, policy: .redacted, reviewed: true))
        try document.add(Annotation(kind: .box, rect: CGRect(x: 20, y: 20, width: 40, height: 40)))
        XCTAssertThrowsError(try ExportPipeline.authorize(preview, document: document, policy: .redacted, reviewed: true)) {
            XCTAssertEqual($0 as? ShotError, .stalePreview)
        }
    }

    func testBranchedEditsWithSameRevisionCannotReusePreview() throws {
        let source = try ShotDocument(source: Fixtures.image())
        var first = source, second = source
        try first.add(Annotation(kind: .box, rect: CGRect(x: 20, y: 20, width: 40, height: 40)))
        try second.add(Annotation(kind: .box, rect: CGRect(x: 40, y: 40, width: 40, height: 40)))
        XCTAssertEqual(first.revision, second.revision)
        let preview = try prepared(first)
        XCTAssertThrowsError(try ExportPipeline.authorize(preview, document: second, policy: .redacted, reviewed: true))
    }

    func testFileExportWritesOnlyApprovedSnapshotAndNeverOverwrites() throws {
        try Fixtures.workspace { directory in
            let originalURL = directory.appendingPathComponent("original.png")
            let image = try Fixtures.image(gradient: true)
            let original = try ImageRenderer.png(image)
            try original.write(to: originalURL)
            let document = try ShotDocument(source: image, sourceURL: originalURL)
            let preview = try prepared(document)
            let output = directory.appendingPathComponent("redacted.png")
            XCTAssertThrowsError(try ExportPipeline.write(preview, to: output, document: document, policy: .redacted, reviewed: false))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            try ExportPipeline.write(preview, to: output, document: document, policy: .redacted, reviewed: true)
            XCTAssertEqual(try Data(contentsOf: output), preview.pngData)
            XCTAssertThrowsError(try ExportPipeline.write(preview, to: originalURL, document: document, policy: .redacted, reviewed: true))
            XCTAssertThrowsError(try ExportPipeline.write(preview, to: output, document: document, policy: .redacted, reviewed: true))
            XCTAssertEqual(try Data(contentsOf: originalURL), original)
            let symlink = directory.appendingPathComponent("linked.png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: originalURL)
            XCTAssertThrowsError(try ExportPipeline.write(preview, to: symlink, document: document, policy: .redacted, reviewed: true))
            XCTAssertThrowsError(try ExportPipeline.write(preview, to: directory.appendingPathComponent("bad.jpg"),
                                                         document: document, policy: .redacted, reviewed: true))
        }
    }

    func testMissingCustomRulesAreEmptyButUnreadableRulesFailClosed() throws {
        try Fixtures.workspace { directory in
            let missing = directory.appendingPathComponent("redact-patterns.txt")
            XCTAssertNoThrow(try CredentialDetector.load(from: missing))
            try Data([0xff, 0xfe, 0xff]).write(to: missing)
            XCTAssertThrowsError(try CredentialDetector.load(from: missing)) {
                guard case ShotError.unreadablePatterns = $0 else { return XCTFail("Wrong error \($0)") }
            }
        }
    }

    func testRealVisionOCRRedactionAndReverificationOnRenderedFixtures() throws {
        let token = "gh" + "p_" + "A1b2C3d4E5f6G7h8" + "I9j0K1l2M3n4O5p6"
        let aws = "AK" + "IA" + "IOSFODNN7" + "EXAMPLE"
        let openAI = "sk" + "-" + "abcdefghijklmnopqrstuvwxyz" + "012345"
        let card = ["4111", "1111", "1111", "1111"].joined(separator: " ")
        let harmless = "ordinary fixture notes remain readable"
        let image = try Fixtures.textImage([
            "Deployment notes for the release",
            "contact: fixture.user@example.test",
            "GITHUB_TOKEN=" + token,
            "AWS key " + aws,
            "api_key: " + openAI,
            "card " + card,
            harmless
        ])
        let recognizer = VisionTextRecognizer()
        let before = try recognizer.recognize(image)
        let detector = try CredentialDetector()
        let labels = Set(before.lines.flatMap { detector.find($0.text).map(\.label) })
        for label in ["email", "github token", "aws access key", "openai-style key", "card-like number"] {
            XCTAssertTrue(labels.contains(label), "Fixture OCR/detection missed \(label)")
        }
        let preview = try ExportPipeline.prepare(ShotDocument(source: image), policy: .redacted, detector: detector)
        XCTAssertGreaterThanOrEqual(preview.automaticRegions.count, 5)
        XCTAssertTrue(preview.text.lowercased().contains("ordinary fixture notes"))
        for secret in [token, aws, openAI, card, "fixture.user@example.test"] {
            XCTAssertFalse(CredentialDetector.stillPresent(secret, in: preview.text))
        }
        XCTAssertTrue(preview.labels.contains("email"))
    }

    func testNewAnnotationCredentialsAreIncludedInAutomaticDetection() throws {
        var document = try ShotDocument(source: Fixtures.textImage(["ordinary fixture notes"]))
        try document.add(Annotation(kind: .text, rect: CGRect(x: 35, y: 85, width: 600, height: 40),
                                    text: "email: test.annotation@example.test", fontSize: 28))
        let preview = try ExportPipeline.prepare(document, policy: .redacted, detector: CredentialDetector())
        XCTAssertTrue(preview.labels.contains("email"))
        XCTAssertFalse(preview.text.contains("test.annotation"))
    }
}
