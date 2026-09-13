import SwiftUI
import RAPPShotCore

struct ShotContentView: View {
    @ObservedObject var model: ShotModel
    @Environment(\.openWindow) private var openWindow
    @State private var smokeScheduled = false

    var body: some View {
        VStack(spacing: 0) {
            if let request = model.pendingAction {
                HStack {
                    Label("External \(request.kind.rawValue) request: review before applying. Nothing has run.", systemImage: "hand.raised")
                    Spacer()
                    Button("Review & Apply") { model.applyPendingAction() }
                        .accessibilityIdentifier("shot.action.apply")
                        .disabled(model.busy)
                    Button("Dismiss") { model.dismissPendingAction() }
                        .accessibilityIdentifier("shot.action.dismiss")
                }.padding().background(.blue.opacity(0.10))
            }
            HSplitView {
                captureSidebar.frame(minWidth: 225, idealWidth: 245, maxWidth: 300)
                editor.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                AnnotationInspector(model: model).frame(minWidth: 230, idealWidth: 250, maxWidth: 310)
            }
            Divider()
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("shot.status")
                Spacer()
                if model.busy {
                    Button("Cancel") { model.cancelOperation() }
                        .accessibilityIdentifier("shot.operation.cancel")
                }
            }.padding(12)
        }
        .frame(minWidth: 940, minHeight: 610)
        .navigationTitle("RAPP Shot")
        .onAppear {
            model.showMainWindow = { openWindow(id: "main") }
            if CommandLine.arguments.contains("--ui-smoke-test"), !smokeScheduled {
                smokeScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NativeDiagnostics.reportStartup(model)
                }
            }
        }
        .sheet(isPresented: $model.showingPreview) {
            if let preview = model.preview { ExportPreviewView(model: model, preview: preview) }
        }
        .alert("RAPP Shot", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var captureSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("RAPP Shot", systemImage: "camera.viewfinder").font(.title2.bold())
                Text("One screenshot. Local processing. Review before it leaves the app.")
                    .font(.callout).foregroundStyle(.secondary)
                GroupBox("Screen Recording") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.workflow.permission == .authorized ? "Available to this app" : "Permission required",
                              systemImage: model.workflow.permission == .authorized ? "checkmark.shield" : "lock.shield")
                            .accessibilityIdentifier("shot.permission.status")
                        if model.workflow.permission != .authorized {
                            Button("Enable Screen Recording") { model.authorizeScreenRecording() }
                                .accessibilityIdentifier("shot.permission.request")
                                .disabled(model.busy)
                        }
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                            .accessibilityIdentifier("shot.permission.settings")
                        Text("If macOS requests it, quit and reopen RAPP Shot after enabling permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Picker("Capture", selection: $model.mode) {
                    ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("shot.capture.mode").disabled(model.busy)
                Button("Refresh Sources (no capture)") { model.refreshSources() }
                    .accessibilityIdentifier("shot.capture.refresh")
                    .disabled(model.busy)
                if model.mode == .window {
                    Picker("Window", selection: $model.windowID) {
                        Text("Choose a window").tag(Optional<CGWindowID>.none)
                        ForEach(model.windows) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("shot.capture.window").disabled(model.busy)
                    Text("Load sources and select a window before capture. Closed windows fail rather than falling back to your entire screen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Display", selection: $model.displayID) {
                        Text("Main display by default").tag(Optional<CGDirectDisplayID>.none)
                        ForEach(model.displays) { Text($0.name).tag(Optional($0.id)) }
                    }.accessibilityIdentifier("shot.capture.display").disabled(model.busy)
                }
                Button {
                    model.capture()
                } label: {
                    Label("Capture \(model.mode.title)…", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("shot.capture.start")
                .disabled(model.busy || (model.mode == .window && model.windowID == nil))
                Text("Region: drag on the selected display. Esc cancels. Captures remain in memory until you export.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Open Image…") { model.importImage() }
                    .accessibilityIdentifier("shot.image.open").disabled(model.busy)
                Button("Open Latest Legacy Shot") { model.openLatestLegacyShot() }
                    .accessibilityIdentifier("shot.image.latest").disabled(model.busy)
                Text("Importing needs no Screen Recording permission. Existing ~/.rappshot files are never replaced.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.title).font(.headline).lineLimit(1)
                    Text("EDITOR • not the export preview").font(.caption.bold()).foregroundStyle(.orange)
                        .accessibilityIdentifier("shot.editor.originalWarning")
                }
                Spacer()
                Button("Undo") { model.undo() }.disabled(!model.canUndo || model.busy)
                    .accessibilityIdentifier("shot.editor.undo")
                Button("Redo") { model.redo() }.disabled(!model.canRedo || model.busy)
                    .accessibilityIdentifier("shot.editor.redo")
            }
            if model.document != nil {
                Picker("Tool", selection: $model.tool) {
                    ForEach(EditorTool.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("shot.editor.tool").disabled(model.busy)
                if model.tool == .text {
                    TextField("Annotation text", text: $model.annotationText)
                        .accessibilityIdentifier("shot.editor.newText").disabled(model.busy)
                }
                EditorCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHint("Choose a tool and drag. Select an annotation to move it, or edit exact source-pixel coordinates in the inspector.")
                if let document = model.document {
                    HStack {
                        Text("\(Int(document.visibleRect.width)) × \(Int(document.visibleRect.height)) px")
                        Spacer()
                        if document.crop != nil {
                            Button("Reset Crop") { model.resetCrop() }
                                .accessibilityIdentifier("shot.editor.resetCrop").disabled(model.busy)
                        }
                    }.font(.caption)
                }
                if !model.contextText.isEmpty {
                    Text(model.contextText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Toggle("Automatic opaque credential redaction", isOn: $model.automaticRedaction)
                    .accessibilityIdentifier("shot.export.automaticRedaction").disabled(model.busy)
                if !model.automaticRedaction {
                    Label("Automatic checks OFF. Manual boxes only; other content may contain secrets.",
                          systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Button("Prepare Export / OCR Preview…") { model.preparePreview() }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                    .accessibilityIdentifier("shot.export.prepare")
            } else {
                ContentUnavailableView {
                    Label("Nothing captured", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Choose Capture or Open Image. RAPP Shot never captures automatically at launch, and never copies an original as a fallback.")
                } actions: {
                    Button("Open an Image…") { model.importImage() }
                        .accessibilityIdentifier("shot.empty.open")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding()
    }
}

struct AnnotationInspector: View {
    @ObservedObject var model: ShotModel

    private func number(_ title: String, id: String,
                        get: @escaping (Annotation) -> CGFloat,
                        set: @escaping (inout Annotation, CGFloat) -> Void) -> some View {
        TextField(title, value: Binding<Double>(
            get: { Double(model.selectedAnnotation.map(get) ?? 0) },
            set: { value in model.editSelected { set(&$0, CGFloat(value)) } }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("shot.annotation.\(id)")
    }

    private func cropNumber(_ title: String, id: String, keyPath: WritableKeyPath<CGRect, CGFloat>) -> some View {
        TextField(title, value: Binding<Double>(
            get: { Double(model.document?.visibleRect[keyPath: keyPath] ?? 0) },
            set: { value in
                guard var rect = model.document?.visibleRect else { return }
                rect[keyPath: keyPath] = CGFloat(value)
                model.setCrop(rect)
            }
        ), format: .number).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("shot.crop.\(id)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Annotations").font(.headline)
                Text("Coordinates use the original image’s top-left pixel origin. Crop is non-destructive; arrows and boxes move with it.")
                    .font(.caption).foregroundStyle(.secondary)
                if let document = model.document {
                    ForEach(Array(document.annotations.enumerated()), id: \.element.id) { index, annotation in
                        Button {
                            model.selectedAnnotationID = annotation.id; model.tool = .select
                        } label: {
                            HStack {
                                Text("\(index + 1). \(annotation.kind.title)")
                                Spacer()
                                if model.selectedAnnotationID == annotation.id { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("shot.annotation.row.\(index)")
                    }
                }
                if let annotation = model.selectedAnnotation {
                    Divider()
                    Text("Edit \(annotation.kind.title.lowercased())").font(.headline)
                    number("X", id: "x", get: { $0.rect.origin.x }, set: { $0.rect.origin.x = $1 })
                    number("Y", id: "y", get: { $0.rect.origin.y }, set: { $0.rect.origin.y = $1 })
                    if annotation.kind == .arrow {
                        number("End X", id: "endX", get: { $0.end.x }, set: { $0.end.x = $1 })
                        number("End Y", id: "endY", get: { $0.end.y }, set: { $0.end.y = $1 })
                    } else {
                        number("Width", id: "width", get: { $0.rect.width }, set: { $0.rect.size.width = $1 })
                        number("Height", id: "height", get: { $0.rect.height }, set: { $0.rect.size.height = $1 })
                    }
                    if annotation.kind == .text {
                        TextField("Text", text: Binding(
                            get: { model.selectedAnnotation?.text ?? "" },
                            set: { value in model.editSelected { $0.text = value } }
                        )).accessibilityIdentifier("shot.annotation.text")
                        number("Font size", id: "fontSize", get: { $0.fontSize }, set: { $0.fontSize = $1 })
                    }
                    if annotation.kind == .box || annotation.kind == .arrow {
                        number("Stroke width", id: "strokeWidth", get: { $0.strokeWidth }, set: { $0.strokeWidth = $1 })
                    }
                    if annotation.kind == .redact {
                        Label("Always opaque black — no blur, alpha, or reversible pixelation.", systemImage: "lock.fill")
                            .font(.caption)
                    } else if annotation.kind != .pixelate {
                        ColorPicker("Color", selection: Binding(
                            get: {
                                let color = model.selectedAnnotation?.color ?? .red
                                return Color(.sRGB, red: Double(color.red), green: Double(color.green),
                                             blue: Double(color.blue), opacity: Double(color.alpha))
                            },
                            set: { color in
                                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                                model.editSelected {
                                    $0.color = AnnotationColor(red: rgb.redComponent, green: rgb.greenComponent,
                                                               blue: rgb.blueComponent, alpha: rgb.alphaComponent)
                                }
                            }
                        )).accessibilityIdentifier("shot.annotation.color")
                    }
                    Button("Delete Annotation", role: .destructive) { model.deleteSelected() }
                        .accessibilityIdentifier("shot.annotation.delete")
                } else {
                    Text("Choose a drawing tool and drag. Select a row to edit or delete it. Text is placed with a click.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if model.document != nil {
                    Text("Crop (source pixels)").font(.headline)
                    cropNumber("X", id: "x", keyPath: \.origin.x)
                    cropNumber("Y", id: "y", keyPath: \.origin.y)
                    cropNumber("Width", id: "width", keyPath: \.size.width)
                    cropNumber("Height", id: "height", keyPath: \.size.height)
                    Text("Drag with Crop or enter exact bounds here. Reset Crop restores the full source.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                Text("Redaction limitations").font(.headline)
                Text("OCR is per-line, not an all-clear. Split, obscured, rotated, or unreadable credentials can be missed. Label matching is English-tuned. Long hex digests may be redacted intentionally. Inspect every exported pixel.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Custom rules: \(model.patternsURL.path)").font(.caption).textSelection(.enabled)
            }.padding().disabled(model.busy)
        }
    }
}

struct ExportPreviewView: View {
    @ObservedObject var model: ShotModel
    let preview: PreparedExport
    @State private var actualSize = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(preview.policy == .redacted ? "Final redacted preview" : "Final edited preview — auto-detection OFF",
                      systemImage: preview.policy == .redacted ? "lock.shield" : "exclamationmark.triangle")
                    .font(.title2.bold()).accessibilityIdentifier("shot.preview.title")
                Spacer()
                Button("Back to Editor") { model.showingPreview = false }
                    .accessibilityIdentifier("shot.preview.close")
            }
            Text(preview.summary).font(.callout).accessibilityIdentifier("shot.preview.summary")
            if !preview.labels.isEmpty {
                Text("Detected classes: " + preview.labels.joined(separator: ", ")).font(.caption)
            }
            Picker("Preview", selection: $model.previewTab) {
                Text("Flattened PNG").tag(0)
                Text("Text from this preview").tag(1)
            }.pickerStyle(.segmented).accessibilityIdentifier("shot.preview.tab")
            if model.previewTab == 0 {
                Toggle("Inspect at 100% pixel size", isOn: $actualSize)
                    .accessibilityIdentifier("shot.preview.actualSize")
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: preview.image, scale: 1)
                            .frame(width: CGFloat(preview.image.width), height: CGFloat(preview.image.height))
                            .accessibilityIdentifier("shot.preview.image")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(decorative: preview.image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("shot.preview.image")
                }
            } else {
                ScrollView {
                    Text(preview.text.isEmpty ? "No text is readable in the final preview." : preview.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("shot.preview.ocrText")
            }
            Text("Review every pixel. OCR, including the verification pass, can miss text. No upload occurs. Copy and Export use exactly this flattened preview, never the source image.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("I reviewed this preview and understand the redaction limitations.", isOn: $model.previewReviewed)
                .accessibilityIdentifier("shot.preview.reviewed")
            HStack {
                Button("Copy PNG") { model.copyPreview() }
                    .accessibilityIdentifier("shot.preview.copyImage")
                Button("Copy Preview Text") { model.copyPreview(text: true) }
                    .accessibilityIdentifier("shot.preview.copyText").disabled(preview.text.isEmpty)
                Spacer()
                Button("Export PNG…") { model.exportPreview() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shot.preview.export")
            }.disabled(!model.previewReviewed)
        }.padding(20).frame(minWidth: 760, idealWidth: 980, minHeight: 580, idealHeight: 780)
    }
}

struct ShotSettingsView: View {
    @ObservedObject var model: ShotModel
    var body: some View {
        Form {
            Section("Native shortcuts") {
                Toggle("Enable system-wide ⌘⇧6 / ⌘⇧7 / ⌘⇧8 while RAPP Shot runs",
                       isOn: Binding(get: { model.globalShortcutsEnabled }, set: { model.setGlobalShortcuts($0) }))
                    .accessibilityIdentifier("shot.settings.globalShortcuts")
                Text("6: region → editor. 7: region → redacted preview. 8: region → OCR preview. All require a user shortcut press; none copies without review. No Hammerspoon or Accessibility permission required. This opt-in is not enabled automatically on launch.")
                    .font(.caption)
            }
            Section("Privacy and permissions") {
                Button("Open Screen Recording Settings") { model.openPrivacySettings() }
                    .accessibilityIdentifier("shot.settings.permissions")
                Text("RAPP Shot requests Screen Recording only. It never requests microphone or camera access. Vision OCR, custom rules, annotation, and PNG export run on this Mac. No cloud service is used.")
                Text("Custom rules are read from \(model.patternsURL.path). Invalid rules block automatic export with an error; Python-only regex extensions may need ICU-compatible syntax.")
            }
            Section("RAPP Shot 1.3.1") {
                Text("macOS 14 or later. The native app needs no Swift compiler, Python, Homebrew, or helper service at runtime. CLI/Hammerspoon compatibility remains separate.")
            }
        }.formStyle(.grouped).padding().frame(width: 600, height: 440)
    }
}
