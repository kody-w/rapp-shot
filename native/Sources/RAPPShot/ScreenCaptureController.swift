import AppKit
import ScreenCaptureKit
import RAPPShotCore

struct DisplaySource: Identifiable {
    let display: SCDisplay
    let name: String
    var id: CGDirectDisplayID { display.displayID }
}

struct WindowSource: Identifiable {
    let window: SCWindow
    var id: CGWindowID { window.windowID }
    var name: String {
        let app = window.owningApplication?.applicationName ?? "Application"
        return "\(app) — \(window.title?.isEmpty == false ? window.title! : "Untitled window")"
    }
}

struct CaptureContext {
    let application: String?
    let title: String?
    let displaySize: CGSize
    var description: String {
        [application, title, "\(Int(displaySize.width)) × \(Int(displaySize.height)) points"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor
final class ScreenCaptureController {
    private var content: SCShareableContent?
    private let selector = RegionSelector()
    var displays: [DisplaySource] = []
    var windows: [WindowSource] = []

    var authorized: Bool { CGPreflightScreenCaptureAccess() }

    func requestAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func refresh() async throws {
        guard authorized else { throw ShotError.permissionRequired }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            content = shareable
            displays = shareable.displays.map { display in
                let name = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                })?.localizedName ?? "Display \(display.displayID)"
                return DisplaySource(display: display, name: name)
            }.sorted { $0.id < $1.id }
            windows = shareable.windows.filter {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier &&
                $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1
            }.map { WindowSource(window: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ShotError { throw error }
        catch { throw ShotError.captureFailed(error.localizedDescription) }
    }

    func region(on displayID: CGDirectDisplayID) async throws -> CGRect {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { throw ShotError.captureFailed("The selected display disconnected") }
        return try await selector.select(on: screen)
    }

    func cancel() { selector.cancel() }

    func capture(mode: CaptureMode, displayID: CGDirectDisplayID?,
                 windowID: CGWindowID?, region: CGRect?) async throws -> (CGImage, CaptureContext) {
        guard authorized else { throw ShotError.permissionDenied }
        guard let content else { throw ShotError.captureFailed("Refresh available sources first") }
        let filter: SCContentFilter
        let context: CaptureContext
        var selection: CGRect?
        if mode == .window {
            guard let selected = windows.first(where: { $0.id == windowID }) else {
                throw ShotError.captureFailed("Select a window; it may have closed")
            }
            filter = SCContentFilter(desktopIndependentWindow: selected.window)
            context = CaptureContext(application: selected.window.owningApplication?.applicationName,
                                     title: selected.window.title, displaySize: selected.window.frame.size)
        } else {
            guard let selected = displays.first(where: { $0.id == displayID }) else {
                throw ShotError.captureFailed("Select a connected display")
            }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: selected.display, excludingApplications: ownApps, exceptingWindows: [])
            if mode == .region {
                guard let region else { throw ShotError.cancelled }
                selection = try PixelGeometry.clippedIntegral(region, in: filter.contentRect.size)
            }
            let front = NSWorkspace.shared.frontmostApplication
            context = CaptureContext(
                application: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.localizedName,
                title: mode == .region ? "Selected region" : selected.name,
                displaySize: selection?.size ?? filter.contentRect.size
            )
        }
        let configuration = SCStreamConfiguration()
        let size = try PixelGeometry.capturePixels(points: selection?.size ?? filter.contentRect.size,
                                                   scale: CGFloat(filter.pointPixelScale))
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        if let selection { configuration.sourceRect = selection }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            try Task.checkCancellation()
            return (image, context)
        } catch is CancellationError { throw CancellationError() }
        catch { throw ShotError.captureFailed(error.localizedDescription) }
    }
}
