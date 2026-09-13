import SwiftUI
import Darwin
import RAPPShotCore

@main
struct RAPPShotApp: App {
    @StateObject private var model: ShotModel
    @NSApplicationDelegateAdaptor(ShotAppDelegate.self) private var delegate

    init() {
        if let exitCode = NativeDiagnostics.handle(Array(CommandLine.arguments.dropFirst())) {
            exit(exitCode)
        }
        _model = StateObject(wrappedValue: ShotModel())
    }

    var body: some Scene {
        Window("RAPP Shot", id: "main") {
            ShotContentView(model: model)
                .onAppear { delegate.connect(model) }
        }
        .defaultSize(width: 1180, height: 790)
        .commands { ShotCommands(model: model) }
        Settings { ShotSettingsView(model: model) }
        MenuBarExtra {
            ShotMenu(model: model)
        } label: {
            Label("RAPP Shot", systemImage: model.busy ? "hourglass" : "camera.viewfinder")
        }
    }
}

@MainActor
final class ShotAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: ShotModel?
    private var pendingURL: URL?
    private var pendingError: Error?

    func connect(_ model: ShotModel) {
        self.model = model
        if let pendingURL {
            self.pendingURL = nil
            model.receive(pendingURL)
        }
        if let pendingError {
            self.pendingError = nil
            model.report(pendingError)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first else {
            let error = ShotError.invalidAction("Open one image or staged action at a time.")
            if let model { model.report(error) } else { pendingError = error }
            return
        }
        if let model { model.receive(url) } else { pendingURL = url }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.activate()
        return true
    }
}

struct ShotCommands: Commands {
    @ObservedObject var model: ShotModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image…") { model.importImage() }.keyboardShortcut("o")
                .disabled(model.busy)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Shot Edit") { model.undo() }.keyboardShortcut("z")
                .disabled(!model.canUndo || model.busy)
            Button("Redo Shot Edit") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo || model.busy)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Prepare Export Preview…") { model.preparePreview() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.document == nil || model.busy)
        }
        CommandMenu("Capture") {
            Button("Region → Editor") { model.mode = .region; model.capture() }
                .keyboardShortcut("6", modifiers: [.command, .shift]).disabled(model.busy)
            Button("Region → Redacted Preview") {
                model.mode = .region; model.automaticRedaction = true; model.capture(showPreviewAfter: true)
            }.keyboardShortcut("7", modifiers: [.command, .shift]).disabled(model.busy)
            Button("Region → OCR Preview") {
                model.mode = .region; model.automaticRedaction = true
                model.capture(showPreviewAfter: true, showTextAfter: true)
            }.keyboardShortcut("8", modifiers: [.command, .shift]).disabled(model.busy)
            Divider()
            Button("Selected Display → Editor") { model.mode = .screen; model.capture() }.disabled(model.busy)
            Button("Cancel Capture / Processing") { model.cancelOperation() }.disabled(!model.busy)
        }
    }
}

struct ShotMenu: View {
    @ObservedObject var model: ShotModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show RAPP Shot") { openWindow(id: "main"); model.activate() }
            .accessibilityIdentifier("shot.menu.show")
        Divider()
        Button("Capture Region…") { model.mode = .region; model.capture() }
            .accessibilityIdentifier("shot.menu.captureRegion").disabled(model.busy)
        Button("Capture Selected Display…") { model.mode = .screen; model.capture() }
            .accessibilityIdentifier("shot.menu.captureDisplay").disabled(model.busy)
        Button("Open Image…") { openWindow(id: "main"); model.importImage() }
            .accessibilityIdentifier("shot.menu.import").disabled(model.busy)
        if model.busy {
            Button("Cancel Current Operation") { model.cancelOperation() }
                .accessibilityIdentifier("shot.menu.cancel")
        }
        Divider()
        Text("No capture at startup • no cloud uploads").font(.caption)
        Button("Quit RAPP Shot") { model.cancelOperation(); NSApp.terminate(nil) }
    }
}
