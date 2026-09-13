import Foundation

public enum CaptureSourceSelection {
    public static func resolve(requested: UInt32?, available: [UInt32], defaultID: UInt32? = nil,
                               requiresSelection: Bool) throws -> UInt32 {
        if let requested {
            guard available.contains(requested) else {
                throw ShotError.captureFailed("The selected source is no longer available. Choose it again; no substitute was captured")
            }
            return requested
        }
        guard !requiresSelection else { throw ShotError.captureFailed("Choose a window before capture") }
        if let defaultID, available.contains(defaultID) { return defaultID }
        guard let first = available.first else { throw ShotError.captureFailed("No connected capture sources") }
        return first
    }
}
