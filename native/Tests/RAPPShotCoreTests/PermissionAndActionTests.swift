import XCTest
@testable import RAPPShotCore

final class PermissionAndActionTests: XCTestCase {
    func testDisconnectedSourcesNeverFallBackToAnotherWindowOrDisplay() throws {
        XCTAssertEqual(try CaptureSourceSelection.resolve(requested: 12, available: [7, 12],
                                                          defaultID: 7, requiresSelection: false), 12)
        XCTAssertEqual(try CaptureSourceSelection.resolve(requested: nil, available: [7, 12],
                                                          defaultID: 12, requiresSelection: false), 12)
        XCTAssertThrowsError(try CaptureSourceSelection.resolve(requested: 12, available: [7],
                                                                 defaultID: 7, requiresSelection: false))
        XCTAssertThrowsError(try CaptureSourceSelection.resolve(requested: 12, available: [7], requiresSelection: true))
        XCTAssertThrowsError(try CaptureSourceSelection.resolve(requested: nil, available: [7], requiresSelection: true))
        XCTAssertThrowsError(try CaptureSourceSelection.resolve(requested: nil, available: [], requiresSelection: false))
    }
    func testStartupAndPreflightCannotTransitionIntoCapture() {
        var workflow = CaptureWorkflow()
        XCTAssertEqual(workflow.phase, .idle)
        XCTAssertEqual(workflow.permission, .unchecked)
        workflow.inspectPermission(granted: true)
        XCTAssertEqual(workflow.phase, .idle)
        XCTAssertThrowsError(try workflow.begin(userInitiated: false)) {
            XCTAssertEqual($0 as? ShotError, .userActionRequired)
        }
        XCTAssertEqual(workflow.phase, .idle)
    }

    func testPermissionDeniedHasActionableRecoveryAndNoCapture() throws {
        var workflow = CaptureWorkflow()
        XCTAssertThrowsError(try workflow.begin(userInitiated: true))
        XCTAssertThrowsError(try workflow.requestPermission(userInitiated: false))
        try workflow.requestPermission(userInitiated: true)
        XCTAssertEqual(workflow.phase, .requestingPermission)
        workflow.permissionResult(granted: false)
        XCTAssertEqual(workflow.permission, .denied)
        XCTAssertEqual(workflow.phase, .failed)
        XCTAssertTrue(workflow.message?.contains("System Settings") == true)
        XCTAssertTrue(workflow.message?.contains("reopen") == true)
        XCTAssertThrowsError(try workflow.begin(userInitiated: true))
    }

    func testCaptureCancellationAndFailurePreserveExplicitStates() throws {
        var workflow = CaptureWorkflow()
        workflow.inspectPermission(granted: true)
        try workflow.begin(userInitiated: true)
        workflow.selectRegion()
        XCTAssertEqual(workflow.phase, .selectingRegion)
        workflow.cancel()
        XCTAssertEqual(workflow.phase, .idle)
        try workflow.begin(userInitiated: true)
        workflow.capture()
        workflow.fail(ShotError.captureFailed("fixture window closed"))
        XCTAssertEqual(workflow.phase, .failed)
        XCTAssertTrue(workflow.message?.contains("fixture window closed") == true)
        workflow.complete()
        XCTAssertEqual(workflow.phase, .editing)
    }

    func testActionURLsAreBoundedDataNotExecutableCommands() throws {
        var components = URLComponents(string: "rappshot://action/annotate")!
        components.queryItems = [
            URLQueryItem(name: "image", value: "/Users/fixture/image with spaces.png"),
            URLQueryItem(name: "text", value: "20,30,quote; $(not executed), with commas"),
            URLQueryItem(name: "box", value: "10,20,30,40"),
            URLQueryItem(name: "arrow", value: "40,50,60,70"),
            URLQueryItem(name: "crop", value: "5,6,100,120"),
            URLQueryItem(name: "copy", value: "true")
        ]
        let request = try NativeAction(url: XCTUnwrap(components.url))
        XCTAssertEqual(request.imageURL?.path, "/Users/fixture/image with spaces.png")
        XCTAssertTrue(request.copyRequested)
        XCTAssertTrue(request.automaticRedaction)
        XCTAssertEqual(request.annotations.count, 3)
        XCTAssertEqual(request.annotations.last?.text, "quote; $(not executed), with commas")
        XCTAssertEqual(request.crop, CGRect(x: 5, y: 6, width: 100, height: 120))
    }

    func testRedactionActionUsesOpaqueManualBoxesAndDoesNotAuthorizeCapture() throws {
        let request = try NativeAction(url: XCTUnwrap(URL(string: "rappshot://action/redact?box=10,20,30,40&auto=false&dry_run=true")))
        XCTAssertEqual(request.annotations.first?.kind, .redact)
        XCTAssertFalse(request.automaticRedaction)
        XCTAssertTrue(request.dryRun)
        let capture = try NativeAction(url: XCTUnwrap(URL(string: "rappshot://action/capture?mode=window")))
        XCTAssertEqual(capture.mode, .window)
        XCTAssertEqual(CaptureWorkflow().phase, .idle)
    }

    func testMalformedUnknownRemoteAndRepeatedActionFieldsAreRejected() {
        let urls = [
            "rappshot://action/delete",
            "https://action/capture",
            "rappshot://action/capture?mode=all",
            "rappshot://action/capture?mode=region&mode=screen",
            "rappshot://action/capture?permission_bypass=true",
            "rappshot://action/redact?copy=yes",
            "rappshot://action/annotate?crop=1,2,-3,4",
            "rappshot://action/annotate?arrow=1,2,nan,4",
            "rappshot://action/ocr?image=https://example.com/image.png",
            "rappshot://action/ocr?image=relative.png",
            "rappshot://action/ocr?image=/path/file.png#fragment"
        ]
        for string in urls {
            guard let url = URL(string: string) else { return XCTFail("Bad test URL") }
            XCTAssertThrowsError(try NativeAction(url: url), string)
        }
    }
}
