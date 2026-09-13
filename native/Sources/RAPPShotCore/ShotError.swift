import Foundation

public enum ShotError: Error, Equatable, LocalizedError {
    case permissionRequired
    case permissionDenied
    case userActionRequired
    case cancelled
    case captureFailed(String)
    case invalidImage
    case invalidGeometry
    case invalidPattern(Int, String)
    case unreadablePatterns(String)
    case noRecognizedText
    case recognitionFailed(String)
    case verificationFailed(Int)
    case previewNotReviewed
    case stalePreview
    case exportFailed(String)
    case wouldOverwrite
    case invalidAction(String)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Screen Recording is required. Click Enable Screen Recording, then allow RAPP Shot in System Settings → Privacy & Security → Screen Recording."
        case .permissionDenied:
            return "Screen Recording is not available to RAPP Shot. Enable it in System Settings, then quit and reopen RAPP Shot if macOS asks. Importing an image needs no screen permission."
        case .userActionRequired:
            return "Capture starts only after you click Capture or use a capture shortcut."
        case .cancelled:
            return "Capture cancelled. Nothing was saved or copied."
        case .captureFailed(let message):
            return "Capture failed: \(message). Refresh the source list and check RAPP Shot’s Screen Recording permission."
        case .invalidImage:
            return "This image could not be decoded, or exceeds the 100-megapixel limit. Open a supported PNG, JPEG, or TIFF."
        case .invalidGeometry:
            return "The selected rectangle must contain pixels inside the image. Coordinates and dimensions must be finite."
        case .invalidPattern(let line, let message):
            return "Custom redaction pattern on line \(line) is invalid: \(message). Correct redact-patterns.txt before exporting with automatic redaction."
        case .unreadablePatterns(let message):
            return "Custom redaction patterns could not be read: \(message). Automatic redaction is blocked, not silently run without your rules."
        case .noRecognizedText:
            return "OCR read zero lines. That is not an all-clear. Automatic redacted export is blocked; inspect the image and use manual redaction with automatic detection disabled if appropriate."
        case .recognitionFailed(let message):
            return "Local Vision OCR failed: \(message). No redacted export or clipboard result was produced."
        case .verificationFailed(let count):
            return "NOT SAFE TO SHARE — \(count) detected credential(s) remain readable after rendering. Add opaque manual redactions, then prepare a new preview."
        case .previewNotReviewed:
            return "Review the final preview and acknowledge the redaction limitations before copying or exporting."
        case .stalePreview:
            return "The image, edits, or redaction policy changed. Prepare and review a new preview."
        case .exportFailed(let message):
            return "Export failed: \(message). The original image has not been replaced."
        case .wouldOverwrite:
            return "RAPP Shot does not overwrite existing images. Choose a new PNG filename."
        case .invalidAction(let message):
            return "Invalid RAPP Shot action: \(message)"
        }
    }
}

public enum ScreenPermission: String, Equatable, Sendable {
    case unchecked, authorized, denied
}

public struct CaptureWorkflow: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case idle, requestingPermission, loadingSources, selectingRegion, capturing, editing, failed
    }
    public private(set) var permission: ScreenPermission = .unchecked
    public private(set) var phase: Phase = .idle
    public private(set) var message: String?

    public init() {}

    public mutating func inspectPermission(granted: Bool) {
        permission = granted ? .authorized : .denied
    }

    public mutating func requestPermission(userInitiated: Bool) throws {
        guard userInitiated else { throw ShotError.userActionRequired }
        phase = .requestingPermission
        message = nil
    }

    public mutating func permissionResult(granted: Bool) {
        inspectPermission(granted: granted)
        phase = granted ? .idle : .failed
        message = granted ? nil : ShotError.permissionDenied.localizedDescription
    }

    public mutating func begin(userInitiated: Bool) throws {
        guard userInitiated else { throw ShotError.userActionRequired }
        guard permission == .authorized else { throw ShotError.permissionRequired }
        phase = .loadingSources
        message = nil
    }

    public mutating func selectRegion() { phase = .selectingRegion }
    public mutating func sourcesReady() { phase = .idle; message = nil }
    public mutating func capture() { phase = .capturing }
    public mutating func complete() { phase = .editing; message = nil }
    public mutating func cancel() { phase = .idle; message = ShotError.cancelled.localizedDescription }
    public mutating func fail(_ error: Error) { phase = .failed; message = error.localizedDescription }
}
