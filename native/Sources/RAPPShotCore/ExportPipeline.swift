import Foundation
import CoreGraphics

public enum ExportPolicy: String, Sendable {
    case redacted, edited
}

public struct PreparedExport {
    public let id: UUID
    public let image: CGImage
    public let pngData: Data
    public let text: String
    public let revision: Int
    public let documentID: UUID
    public let editID: UUID
    public let policy: ExportPolicy
    public let automaticRegions: [CGRect]
    public let labels: [String]
    public let manualRedactions: Int
    public let sourceURL: URL?

    init(image: CGImage, pngData: Data, text: String, document: ShotDocument, policy: ExportPolicy,
         automaticRegions: [CGRect], labels: [String], manualRedactions: Int, sourceURL: URL?) {
        id = UUID(); self.image = image; self.pngData = pngData; self.text = text
        revision = document.revision; documentID = document.id; editID = document.editID
        self.policy = policy
        self.automaticRegions = automaticRegions; self.labels = labels
        self.manualRedactions = manualRedactions; self.sourceURL = sourceURL
    }

    public var summary: String {
        if policy == .redacted {
            return "\(automaticRegions.count) detected line(s) painted opaquely; output re-read with Vision. This checks detected text only, not that the image contains no secrets."
        }
        return "Automatic detection OFF. \(manualRedactions) manual opaque region(s). Other content has not been checked for credentials."
    }
}

public enum ExportPipeline {
    public static func prepare(_ document: ShotDocument, policy: ExportPolicy,
                               detector: CredentialDetector,
                               recognizer: TextRecognizing = VisionTextRecognizer()) throws -> PreparedExport {
        try Task.checkCancellation()
        let base = try ImageRenderer.render(document)
        var result = base
        var regions: [CGRect] = []
        var hits: [CredentialHit] = []
        let before = try recognizer.recognize(base)
        var after = before
        if policy == .redacted {
            guard !before.lines.isEmpty else { throw ShotError.noRecognizedText }
            for line in before.lines {
                let found = detector.find(line.text)
                guard !found.isEmpty else { continue }
                // Per-line boxes deliberately match the CLI. Integral outward padding protects glyph edges.
                regions.append(try PixelGeometry.clippedIntegral(line.rect.insetBy(dx: -3, dy: -3), in: before.imageSize))
                hits += found
            }
            try Task.checkCancellation()
            result = try ImageRenderer.redact(base, regions: regions)
            after = try recognizer.recognize(result)
            let survivors = hits.filter { CredentialDetector.stillPresent($0.text, in: after.text) }
            let remaining = after.lines.flatMap { detector.find($0.text) }
            guard survivors.isEmpty && remaining.isEmpty else {
                throw ShotError.verificationFailed(max(survivors.count, remaining.count))
            }
            if regions.isEmpty && after.lines.isEmpty { throw ShotError.noRecognizedText }
        }
        try Task.checkCancellation()
        return PreparedExport(image: result, pngData: try ImageRenderer.png(result), text: after.text,
                              document: document, policy: policy, automaticRegions: regions,
                              labels: Array(Set(hits.map(\.label))).sorted(),
                              manualRedactions: document.annotations.filter {
                                  $0.kind == .redact && !$0.rect.intersection(document.visibleRect).isEmpty &&
                                      !$0.rect.intersection(document.visibleRect).isNull
                              }.count,
                              sourceURL: document.sourceURL)
    }

    public static func authorize(_ preview: PreparedExport, document: ShotDocument,
                                 policy: ExportPolicy, reviewed: Bool) throws {
        guard preview.documentID == document.id, preview.editID == document.editID,
              preview.revision == document.revision, preview.policy == policy else { throw ShotError.stalePreview }
        guard reviewed else { throw ShotError.previewNotReviewed }
    }

    public static func write(_ preview: PreparedExport, to url: URL, document: ShotDocument,
                             policy: ExportPolicy, reviewed: Bool) throws {
        try authorize(preview, document: document, policy: policy, reviewed: reviewed)
        guard url.isFileURL, url.pathExtension.lowercased() == "png" else {
            throw ShotError.exportFailed("Choose a local .png filename.")
        }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        guard target != preview.sourceURL?.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: url.path) else { throw ShotError.wouldOverwrite }
        do { try preview.pngData.write(to: url, options: .withoutOverwriting) }
        catch { throw ShotError.exportFailed(error.localizedDescription) }
    }
}
