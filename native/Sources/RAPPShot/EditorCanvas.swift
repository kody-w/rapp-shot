import SwiftUI
import AppKit
import RAPPShotCore

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var model: ShotModel

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView()
        view.setAccessibilityIdentifier("shot.editor.canvas")
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Editable screenshot. This is not the export preview.")
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.image = model.editorImage
        view.enabled = !model.busy
        view.tool = model.tool
        if let annotation = model.selectedAnnotation, let document = model.document {
            let rect = annotation.kind == .arrow ?
                PixelGeometry.rectangle(from: annotation.rect.origin, to: annotation.end) : annotation.rect
            view.selected = rect.offsetBy(dx: -document.visibleRect.minX, dy: -document.visibleRect.minY)
        } else { view.selected = nil }
        view.onGesture = { [weak model] start, end in model?.editorGesture(start: start, end: end) }
        view.needsDisplay = true
    }
}

final class CanvasView: NSView {
    var image: CGImage?
    var selected: CGRect?
    var tool: EditorTool = .select
    var enabled = true
    var onGesture: ((CGPoint, CGPoint) -> Void)?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var transform: ViewportTransform? {
        guard let image, bounds.width > 0, bounds.height > 0 else { return nil }
        // Geometry has already been validated when the document was loaded.
        return try? ViewportTransform(imageSize: CGSize(width: image.width, height: image.height), viewport: bounds.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image, let transform else { return }
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            .draw(in: transform.contentRect, from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if let selected {
            NSColor.systemBlue.setStroke()
            let selection = NSBezierPath(rect: transform.viewRect(selected).insetBy(dx: -2, dy: -2))
            selection.lineWidth = 2
            selection.setLineDash([5, 3], count: 2, phase: 0)
            selection.stroke()
        }
        if let start = dragStart, let end = dragEnd, tool != .select {
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath()
            if tool == .arrow {
                path.move(to: transform.viewPoint(start)); path.line(to: transform.viewPoint(end))
            } else {
                path.appendRect(transform.viewRect(PixelGeometry.rectangle(from: start, to: end)))
            }
            path.lineWidth = 2; path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let transform,
              let point = transform.imagePoint(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        dragStart = point; dragEnd = point; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, dragStart != nil, let transform else { return }
        dragEnd = transform.imagePoint(convert(event.locationInWindow, from: nil), clamp: true)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragEnd = nil; needsDisplay = true }
        guard enabled, let start = dragStart, let transform,
              let end = transform.imagePoint(convert(event.locationInWindow, from: nil), clamp: true) else { return }
        onGesture?(start, end)
    }
}
