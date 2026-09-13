import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RAPPShotCore
import RAPPDesktopSupport

enum EditorTool: String, CaseIterable, Identifiable {
    case select, crop, box, arrow, text, highlight, redact, pixelate
    var id: String { rawValue }
    var title: String { self == .pixelate ? "Pixelate (not redaction)" : rawValue.capitalized }
}

@MainActor
final class ShotModel: ObservableObject {
    @Published private(set) var workflow = CaptureWorkflow()
    @Published private(set) var displays: [DisplaySource] = []
    @Published private(set) var windows: [WindowSource] = []
    @Published var mode: CaptureMode = .region
    @Published var displayID: CGDirectDisplayID?
    @Published var windowID: CGWindowID?
    @Published private(set) var document: ShotDocument?
    @Published private(set) var editorImage: CGImage?
    @Published private(set) var contextText = ""
    @Published private(set) var title = "No screenshot"
    @Published private(set) var busy = false
    @Published var status = "Ready. Nothing is captured, saved, or copied on launch."
    @Published var errorMessage: String?
    @Published var tool: EditorTool = .select
    @Published var selectedAnnotationID: UUID?
    @Published var annotationText = "Note"
    @Published var automaticRedaction = true {
        didSet { if oldValue != automaticRedaction { invalidatePreview() } }
    }
    @Published private(set) var preview: PreparedExport?
    @Published var showingPreview = false
    @Published var previewReviewed = false
    @Published var previewTab = 0
    @Published private(set) var pendingAction: NativeAction?
    @Published private(set) var globalShortcutsEnabled = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private(set) var captureAttempts = 0
    private(set) var sourceRefreshAttempts = 0
    private(set) var permissionRequests = 0

    private let captureController = ScreenCaptureController()
    private let hotkeys = NativeHotkeys()
    private var operation: Task<Void, Never>?
    private var worker: Task<PreparedExport, Error>?
    private var jobID = UUID()
    private var undoStack: [ShotDocument] = []
    private var redoStack: [ShotDocument] = []
    private var pendingCaptureName: String?
    var showMainWindow: (() -> Void)?

    init() {
        // Preflight is read-only: neither this initializer nor a URL launch starts capture or prompts TCC.
        workflow.inspectPermission(granted: captureController.authorized)
        hotkeys.onPress = { [weak self] id in
            guard let self else { return }
            self.mode = .region
            if id == 2 || id == 3 { self.automaticRedaction = true }
            self.capture(showPreviewAfter: id != 1, showTextAfter: id == 3)
        }
    }

    var policy: ExportPolicy { automaticRedaction ? .redacted : .edited }
    var selectedAnnotation: Annotation? {
        document?.annotations.first { $0.id == selectedAnnotationID }
    }
    var legacyRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SHOT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rappshot", isDirectory: true)
    }
    var patternsURL: URL { legacyRoot.appendingPathComponent("redact-patterns.txt") }

    func activate() {
        showMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue != "com.apple.SwiftUI.Settings" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            report(ShotError.captureFailed("Open System Settings → Privacy & Security → Screen Recording manually"))
            return
        }
    }

    func authorizeScreenRecording() {
        guard !busy else { return }
        do {
            try workflow.requestPermission(userInitiated: true)
            permissionRequests += 1
            let allowed = captureController.requestAuthorization()
            workflow.permissionResult(granted: allowed)
            if allowed { status = "Permission available. Choose a source and click Capture."; refreshSources() }
            else { report(ShotError.permissionDenied) }
        } catch { report(error) }
    }

    func refreshSources() {
        guard !busy else { return }
        workflow.inspectPermission(granted: captureController.authorized)
        do { try workflow.begin(userInitiated: true) }
        catch { report(error); return }
        busy = true
        status = "Loading capture sources — no screenshot is being taken."
        let job = UUID(); jobID = job
        operation = Task {
            defer { finish(job) }
            do {
                sourceRefreshAttempts += 1
                try await captureController.refresh()
                guard job == jobID, !Task.isCancelled else { return }
                synchronizeSources()
                workflow.sourcesReady()
                status = "Sources ready. Select a display or window, then click Capture."
            } catch { handleOperationError(error, job: job) }
        }
    }

    private func synchronizeSources() {
        displays = captureController.displays
        windows = captureController.windows
        if !displays.contains(where: { $0.id == displayID }) {
            displayID = displays.first(where: { $0.id == CGMainDisplayID() })?.id ?? displays.first?.id
        }
        if !windows.contains(where: { $0.id == windowID }) { windowID = windows.first?.id }
    }

    func capture(showPreviewAfter: Bool = false, showTextAfter: Bool = false) {
        guard !busy else { return }
        workflow.inspectPermission(granted: captureController.authorized)
        do { try workflow.begin(userInitiated: true) }
        catch { activate(); report(error); return }
        invalidatePreview()
        busy = true
        status = "Loading sources for your requested capture…"
        let job = UUID(); jobID = job
        let requestedMode = mode
        let requestedDisplayID = displayID
        let requestedWindowID = windowID
        operation = Task {
            var prepareAfterFinishing = false
            do {
                sourceRefreshAttempts += 1
                try await captureController.refresh()
                guard job == jobID, !Task.isCancelled else { finish(job); return }
                displays = captureController.displays
                windows = captureController.windows
                if requestedMode == .window {
                    windowID = try CaptureSourceSelection.resolve(requested: requestedWindowID,
                                                                  available: windows.map(\.id), requiresSelection: true)
                } else {
                    displayID = try CaptureSourceSelection.resolve(requested: requestedDisplayID, available: displays.map(\.id),
                                                                   defaultID: CGMainDisplayID(), requiresSelection: false)
                }
                var selection: CGRect?
                if requestedMode == .region {
                    guard let displayID else { throw ShotError.captureFailed("No connected displays") }
                    workflow.selectRegion()
                    status = "Selecting a region. Drag on the chosen display; Esc cancels."
                    selection = try await captureController.region(on: displayID)
                }
                try Task.checkCancellation()
                workflow.capture()
                status = "Capturing one \(requestedMode.title.lowercased())… Cancel discards any late result."
                captureAttempts += 1
                let (image, context) = try await captureController.capture(
                    mode: requestedMode, displayID: displayID, windowID: windowID, region: selection)
                guard job == jobID, !Task.isCancelled else { finish(job); return }
                try installDocument(ShotDocument(source: image), name: pendingCaptureName ?? "Untitled capture")
                pendingCaptureName = nil
                contextText = context.description
                workflow.complete()
                status = "Captured into memory only. Edit, then prepare and review an export preview."
                activate()
                prepareAfterFinishing = showPreviewAfter
            } catch { handleOperationError(error, job: job) }
            finish(job)
            if prepareAfterFinishing { preparePreview(showText: showTextAfter) }
        }
    }

    func cancelOperation() {
        jobID = UUID()
        operation?.cancel(); worker?.cancel(); captureController.cancel()
        operation = nil; worker = nil; busy = false
        workflow.cancel()
        status = "Cancelled. No new image was saved or copied."
        activate()
    }

    private func finish(_ job: UUID) {
        guard job == jobID else { return }
        busy = false; operation = nil; worker = nil
    }

    private func handleOperationError(_ error: Error, job: UUID) {
        guard job == jobID else { return }
        if let windowID, !windows.contains(where: { $0.id == windowID }) { self.windowID = nil }
        if let displayID, !displays.contains(where: { $0.id == displayID }) { self.displayID = nil }
        if error is CancellationError || (error as? ShotError) == .cancelled {
            workflow.cancel(); status = "Cancelled. Nothing saved or copied."
        } else { workflow.fail(error); report(error) }
        activate()
    }

    func importImage() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openImage(url) }
    }

    @discardableResult
    func openImage(_ url: URL) -> Bool {
        guard !busy else { report(ShotError.invalidAction("Finish or cancel the current operation first.")); return false }
        do {
            try installDocument(ShotDocument(source: ImageRenderer.load(url), sourceURL: url),
                                name: url.lastPathComponent)
            status = "Imported for editing. The original file will not be overwritten."
            return true
        } catch { report(error); return false }
    }

    private func installDocument(_ document: ShotDocument, name: String) throws {
        let image = try ImageRenderer.render(document)
        invalidatePreview()
        self.document = document; editorImage = image; title = name; contextText = ""
        undoStack = []; redoStack = []; selectedAnnotationID = nil
        canUndo = false; canRedo = false
    }

    @discardableResult
    func openLatestLegacyShot() -> Bool {
        do {
            let directory = legacyRoot.appendingPathComponent("shots", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let sorted = try files.filter { $0.pathExtension.lowercased() == "png" }.map {
                ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
            guard let latest = sorted.first?.0 else { throw ShotError.invalidAction("No legacy PNG shots were found. Import an image or capture one.") }
            return openImage(latest)
        } catch { report(error); return false }
    }

    @discardableResult
    private func mutate(_ body: (inout ShotDocument) throws -> Void) -> Bool {
        guard !busy, var updated = document, let current = document else { return false }
        do {
            try body(&updated)
            let image = try ImageRenderer.render(updated)
            undoStack.append(current)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            document = updated; editorImage = image
            canUndo = true; canRedo = false
            invalidatePreview()
            return true
        } catch { report(error); return false }
    }

    func undo() {
        guard !busy, let current = document, let previous = undoStack.last else { return }
        do {
            let image = try ImageRenderer.render(previous)
            undoStack.removeLast(); redoStack.append(current)
            document = previous; editorImage = image
            canUndo = !undoStack.isEmpty; canRedo = true; selectedAnnotationID = nil
            invalidatePreview()
        } catch { report(error) }
    }

    func redo() {
        guard !busy, let current = document, let next = redoStack.last else { return }
        do {
            let image = try ImageRenderer.render(next)
            redoStack.removeLast(); undoStack.append(current)
            document = next; editorImage = image
            canRedo = !redoStack.isEmpty; canUndo = true; selectedAnnotationID = nil
            invalidatePreview()
        } catch { report(error) }
    }

    func resetCrop() { mutate { try $0.setCrop(nil) } }
    func setCrop(_ rect: CGRect) { mutate { try $0.setCrop(rect) } }
    func deleteSelected() {
        guard let id = selectedAnnotationID else { return }
        mutate { $0.remove(id) }; selectedAnnotationID = nil
    }
    func editSelected(_ update: (inout Annotation) -> Void) {
        guard var annotation = selectedAnnotation else { return }
        update(&annotation)
        mutate { try $0.update(annotation) }
    }

    func editorGesture(start: CGPoint, end: CGPoint) {
        guard !busy, let document else { return }
        let offset = document.visibleRect.origin
        let first = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
        let last = CGPoint(x: end.x + offset.x, y: end.y + offset.y)
        let rect = PixelGeometry.rectangle(from: first, to: last)
        if tool == .select {
            let hit = document.annotations.reversed().first {
                let bounds = $0.kind == .arrow ? PixelGeometry.rectangle(from: $0.rect.origin, to: $0.end) : $0.rect
                return bounds.insetBy(dx: -8, dy: -8).contains(first)
            }
            selectedAnnotationID = hit?.id
            if let hit, rect.width + rect.height > 2 {
                let dx = last.x - first.x, dy = last.y - first.y
                var moved = hit
                moved.rect = moved.rect.offsetBy(dx: dx, dy: dy)
                moved.end = CGPoint(x: moved.end.x + dx, y: moved.end.y + dy)
                mutate { try $0.update(moved) }
            }
            return
        }
        if tool == .crop {
            guard rect.width >= 1, rect.height >= 1 else { return }
            mutate { try $0.setCrop(rect) }
            return
        }
        guard let kind = Annotation.Kind(rawValue: tool.rawValue) else { return }
        if kind != .text && kind != .arrow && (rect.width < 1 || rect.height < 1) { return }
        let bounds = kind == .arrow ? CGRect(origin: first, size: .zero) :
            kind == .text ? CGRect(x: first.x, y: first.y, width: 240, height: 44) : rect
        let annotation = Annotation(kind: kind, rect: bounds, end: last, text: annotationText)
        mutate { try $0.add(annotation) }
        selectedAnnotationID = annotation.id
    }

    private func invalidatePreview() {
        preview = nil; showingPreview = false; previewReviewed = false
    }

    func preparePreview(showText: Bool = false) {
        guard !busy, let document else { return }
        invalidatePreview()
        let detector: CredentialDetector
        do { detector = try CredentialDetector.load(from: patternsURL) }
        catch { report(error); return }
        busy = true
        let job = UUID(); jobID = job
        let selectedPolicy = policy
        status = selectedPolicy == .redacted ? "Reading, painting opaque redactions, then re-reading the output locally…" : "Rendering edited preview and reading its text locally…"
        let worker = Task.detached(priority: .userInitiated) {
            try ExportPipeline.prepare(document, policy: selectedPolicy, detector: detector)
        }
        self.worker = worker
        operation = Task {
            defer { finish(job) }
            do {
                let output = try await worker.value
                guard job == jobID, !Task.isCancelled, self.document?.editID == document.editID,
                      self.document?.id == document.id, policy == selectedPolicy else { return }
                preview = output; previewReviewed = false; previewTab = showText ? 1 : 0; showingPreview = true
                status = output.summary
            } catch { handleOperationError(error, job: job) }
        }
    }

    private func authorizedPreview() throws -> PreparedExport {
        guard let document, let preview else { throw ShotError.stalePreview }
        try ExportPipeline.authorize(preview, document: document, policy: policy, reviewed: previewReviewed)
        return preview
    }

    func copyPreview(text: Bool = false) {
        do {
            let preview = try authorizedPreview()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let copied = text ? pasteboard.setString(preview.text, forType: .string) :
                pasteboard.setData(preview.pngData, forType: .png)
            guard copied else { throw ShotError.exportFailed("The clipboard rejected the prepared result. Try again.") }
            status = text ? "Copied only the reviewed preview’s OCR text." : "Copied only the reviewed, flattened PNG preview."
        } catch { report(error) }
    }

    func exportPreview() {
        do {
            let preview = try authorizedPreview()
            guard let document else { throw ShotError.stalePreview }
            let directory = try ApplicationDirectories.support(bundleID: "io.rapp.shot").appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            panel.directoryURL = directory
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            panel.nameFieldStringValue = "Shot-\(stamp)\(policy == .redacted ? ".redacted" : ".edited").png"
            panel.message = "Only the reviewed, flattened PNG is exported. Existing images are never overwritten."
            if panel.runModal() == .OK, let url = panel.url {
                try ExportPipeline.write(preview, to: url, document: document, policy: policy, reviewed: previewReviewed)
                status = "Exported \(url.lastPathComponent). The original remains unchanged."
            }
        } catch { report(error) }
    }

    func setGlobalShortcuts(_ enabled: Bool) {
        if !enabled { hotkeys.disable(); globalShortcutsEnabled = false; return }
        do { try hotkeys.enable(); globalShortcutsEnabled = true }
        catch { globalShortcutsEnabled = false; report(error) }
    }

    func receive(_ url: URL) {
        activate()
        if url.isFileURL { openImage(url); return }
        do {
            pendingAction = try NativeAction(url: url)
            status = "An external action is staged for review. No capture, copy, or export has run."
        } catch { report(error) }
    }

    func dismissPendingAction() { pendingAction = nil }

    func applyPendingAction() {
        guard !busy, let action = pendingAction else { return }
        pendingAction = nil
        if action.kind == .capture {
            mode = action.mode
            automaticRedaction = action.automaticRedaction
            pendingCaptureName = action.name
            status = "Capture request staged. Choose a source and click Capture. Copy still requires a reviewed preview."
            return
        }
        if let url = action.imageURL {
            guard openImage(url) else { return }
        } else if document == nil {
            guard openLatestLegacyShot() else { return }
        }
        guard document != nil else { return }
        if action.crop != nil || !action.annotations.isEmpty {
            guard mutate({ document in
                if let crop = action.crop { try document.setCrop(crop) }
                for annotation in action.annotations { try document.add(annotation) }
            }) else { return }
        }
        automaticRedaction = action.automaticRedaction
        status = action.dryRun ? "Dry-run request: prepare a preview to inspect detected regions; no output is written." :
            "Action loaded for review. Prepare the preview; copying and exporting still require your approval."
        if action.kind == .ocr { tool = .select }
    }
}
