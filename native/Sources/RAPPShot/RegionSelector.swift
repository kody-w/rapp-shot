import AppKit
import RAPPShotCore

@MainActor
final class RegionSelector {
    private var window: RegionWindow?
    private var continuation: CheckedContinuation<CGRect, Error>?

    func select(on screen: NSScreen) async throws -> CGRect {
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let panel = RegionWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] result in self?.finish(result) }
            panel.contentView = view
            window = panel
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func cancel() { finish(.failure(ShotError.cancelled)) }

    private func finish(_ result: Result<CGRect, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        window?.orderOut(nil); window?.close(); window = nil
        continuation.resume(with: result)
    }
}

private final class RegionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    var onFinish: ((Result<CGRect, Error>) -> Void)?
    private var start: CGPoint?
    private var selected: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("shot.capture.region.overlay")
        setAccessibilityLabel("Drag a screenshot region. Escape cancels without capturing.")
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()
        if let selected {
            NSColor.clear.setFill()
            selected.fill(using: .copy)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: selected)
            path.lineWidth = 3; path.stroke()
        }
        let text = "Drag to select a region  •  Release to capture  •  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black
        ]
        (text as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selected = nil; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        selected = PixelGeometry.rectangle(from: start, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let rect = PixelGeometry.rectangle(from: start, to: convert(event.locationInWindow, from: nil)).intersection(bounds)
        if rect.width >= 2 && rect.height >= 2 { onFinish?(.success(rect)) }
        else { self.start = nil; selected = nil; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(.failure(ShotError.cancelled)) }
        else { super.keyDown(with: event) }
    }
}
