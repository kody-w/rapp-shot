import Foundation
import CoreGraphics
import RAPPShotCore
import RAPPDesktopSupport
import AppKit
import Darwin

enum NativeDiagnostics {
    static func handle(_ arguments: [String]) -> Int32? {
        guard let first = arguments.first, first.hasPrefix("--") else { return nil }
        do {
            switch first {
            case "--ui-smoke-test":
                guard arguments.count == 1 else { throw ShotError.invalidAction("--ui-smoke-test takes no other arguments.") }
                return nil
            case "--diagnose":
                guard arguments.count == 1 else { throw ShotError.invalidAction("--diagnose takes no other arguments.") }
                try output([
                    "product": "RAPPShot", "displayName": "RAPP Shot", "version": "1.3.1",
                    "minimumMacOS": "14.0", "bundleID": "io.rapp.shot",
                    "screenRecording": CGPreflightScreenCaptureAccess() ? "authorized" : "required",
                    "permissionScope": "current process; verify the normally launched GUI app separately",
                    "captureAttempted": false, "captureOnLaunch": false, "clipboardWritten": false,
                    "localOCR": "Apple Vision", "runtimeHelpersRequired": [],
                    "actions": ["doctor", "capture", "ocr", "redact", "annotate", "list"]
                ])
            case "--detect-lines":
                guard arguments.count == 1 else { throw ShotError.invalidAction("--detect-lines takes JSON on stdin only.") }
                let limit = 2_000_000
                let data = try boundedInput(limit: limit)
                guard data.count <= limit, let lines = try JSONSerialization.jsonObject(with: data) as? [String],
                      lines.count <= 5_000, lines.allSatisfy({ $0.utf8.count <= 16_384 }) else {
                    throw ShotError.invalidAction("Expected at most 5000 lines / 2 MB of fixture JSON.")
                }
                let detector = try CredentialDetector()
                let results = lines.map { line in
                    ["labels": Array(Set(detector.find(line).map(\.label))).sorted()]
                }
                try output(results)
            case "--agent-list":
                let limit: Int
                if arguments.count == 1 { limit = 20 }
                else if arguments.count == 3, arguments[1] == "--limit", let count = Int(arguments[2]), (1...100).contains(count) {
                    limit = count
                } else { throw ShotError.invalidAction("--agent-list accepts --limit 1 through 100.") }
                let home = FileManager.default.homeDirectoryForCurrentUser
                let legacy = ProcessInfo.processInfo.environment["SHOT_HOME"].map {
                    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
                } ?? home.appendingPathComponent(".rappshot", isDirectory: true)
                let native = try ApplicationDirectories.support(bundleID: "io.rapp.shot")
                var files: [(Date, [String: Any])] = []
                for directory in [legacy.appendingPathComponent("shots"), native.appendingPathComponent("Exports")] {
                    guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                    let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
                    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                    for url in urls.filter({ $0.pathExtension.lowercased() == "png" }) {
                        let values = try url.resourceValues(forKeys: keys)
                        guard values.isRegularFile == true else { continue }
                        files.append((values.contentModificationDate ?? .distantPast,
                                      ["file": url.path, "bytes": values.fileSize ?? 0]))
                    }
                }
                try output(["shots": files.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1), "captureAttempted": false])
            default:
                throw ShotError.invalidAction("Use --diagnose, --agent-list, --detect-lines, --ui-smoke-test, or open the app normally.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 2
        }
    }

    private static func boundedInput(limit: Int) throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(15)
        while data.count <= limit {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0, poll(&descriptor, 1, remaining) > 0 else {
                throw ShotError.invalidAction("Fixture input timed out after 15 seconds.")
            }
            let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }

    @MainActor
    static func reportStartup(_ model: ShotModel) {
        let visibleWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count
        let safe = !model.busy && model.document == nil && model.workflow.phase == .idle &&
            model.displays.isEmpty && model.windows.isEmpty && visibleWindows > 0 &&
            !model.globalShortcutsEnabled && model.captureAttempts == 0 &&
            model.sourceRefreshAttempts == 0 && model.permissionRequests == 0 && model.pendingAction == nil
        do {
            try output(["uiStartup": safe ? "passed" : "failed", "visibleMainWindows": visibleWindows,
                        "captureState": model.workflow.phase.rawValue, "hasImage": model.document != nil,
                        "sourceEnumerationAttempts": model.sourceRefreshAttempts,
                        "captureAttempts": model.captureAttempts, "permissionRequests": model.permissionRequests,
                        "clipboardWritten": false])
            exit(safe ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func output(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
