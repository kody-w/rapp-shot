import Foundation

public enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case region, window, screen
    public var id: String { rawValue }
    public var title: String { self == .screen ? "Display" : rawValue.capitalized }
}

public struct NativeAction {
    public enum Kind: String { case capture, ocr, redact, annotate }
    public let kind: Kind
    public let mode: CaptureMode
    public let imageURL: URL?
    public let name: String?
    public let automaticRedaction: Bool
    public let copyRequested: Bool
    public let dryRun: Bool
    public let annotations: [Annotation]
    public let crop: CGRect?

    public init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 16_384,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "rappshot", components.host == "action",
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let kind = Kind(rawValue: String(components.path.dropFirst())) else {
            throw ShotError.invalidAction("Expected rappshot://action/capture, ocr, redact, or annotate.")
        }
        let allowed: Set<String> = ["image", "mode", "name", "auto", "copy", "dry_run", "box", "arrow", "crop", "text"]
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard allowed.contains(item.name), fields[item.name] == nil,
                  let value = item.value else { throw ShotError.invalidAction("Unknown or repeated parameter.") }
            fields[item.name] = value
        }
        func boolean(_ key: String, default fallback: Bool) throws -> Bool {
            guard let value = fields[key] else { return fallback }
            switch value { case "true", "1": return true; case "false", "0": return false
            default: throw ShotError.invalidAction("\(key) must be true or false.") }
        }
        func numbers(_ value: String) throws -> [CGFloat] {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let result: [CGFloat] = parts.compactMap { Double($0).map { CGFloat($0) } }
            guard parts.count == 4, result.count == 4, result.allSatisfy(\.isFinite),
                  result.allSatisfy({ abs($0) <= 100_000 }) else {
                throw ShotError.invalidAction("Coordinates must be four finite numbers.")
            }
            return result
        }
        func rectangle(_ value: String) throws -> CGRect {
            let n = try numbers(value)
            guard n[2] > 0, n[3] > 0 else { throw ShotError.invalidGeometry }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        self.kind = kind
        guard let mode = CaptureMode(rawValue: fields["mode"] ?? "region") else {
            throw ShotError.invalidAction("mode must be region, window, or screen.")
        }
        self.mode = mode
        if let path = fields["image"] {
            guard !path.isEmpty, !path.contains("://"), path.utf8.count <= 4_096,
                  !path.contains("\0") else { throw ShotError.invalidAction("image must be a local file path.") }
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ShotError.invalidAction("Use an absolute image path.") }
            imageURL = URL(fileURLWithPath: expanded)
        } else { imageURL = nil }
        name = fields["name"].map { String($0.prefix(120)) }
        automaticRedaction = try boolean("auto", default: true)
        copyRequested = try boolean("copy", default: false)
        dryRun = try boolean("dry_run", default: false)
        crop = try fields["crop"].map(rectangle)
        var annotations: [Annotation] = []
        if let box = fields["box"] {
            annotations.append(Annotation(kind: kind == .redact ? .redact : .box, rect: try rectangle(box)))
        }
        if let arrow = fields["arrow"] {
            let n = try numbers(arrow)
            annotations.append(Annotation(kind: .arrow,
                                          rect: CGRect(x: n[0], y: n[1], width: 0, height: 0),
                                          end: CGPoint(x: n[2], y: n[3])))
        }
        if let text = fields["text"] {
            let parts = text.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]),
                  x.isFinite, y.isFinite, abs(x) <= 100_000, abs(y) <= 100_000,
                  !parts[2].isEmpty else { throw ShotError.invalidAction("text must be x,y,message.") }
            annotations.append(Annotation(kind: .text, rect: CGRect(x: x, y: y, width: 240, height: 44),
                                          text: String(parts[2])))
        }
        for annotation in annotations { try annotation.validate() }
        self.annotations = annotations
    }
}
