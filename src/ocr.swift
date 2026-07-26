// rapp-shot OCR shim — Apple Vision text recognition with bounding boxes.
// usage: ocr <image>
// prints {"path":…,"text":…,"lines":n,"confidence":…,"boxes":[{t,x,y,w,h,c}]}
//
// Boxes are in TOP-LEFT pixel coordinates, already converted from Vision's
// bottom-left normalised space, so callers never have to redo that flip.
import Foundation
import Vision
import AppKit

func recognize(_ path: String) -> [String: Any] {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return ["path": path, "error": "cannot read image"]
    }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req]) } catch {
        return ["path": path, "error": "\(error)"]
    }
    var lines: [String] = []
    var boxes: [[String: Any]] = []
    var conf: Float = 0
    for o in (req.results ?? []) {
        guard let top = o.topCandidates(1).first else { continue }
        lines.append(top.string)
        conf += top.confidence
        let b = o.boundingBox      // normalised, origin bottom-left
        boxes.append([
            "t": top.string,
            "x": Int(b.minX * w),
            "y": Int((1 - b.maxY) * h),   // flip to top-left origin
            "w": Int(b.width * w),
            "h": Int(b.height * h),
            "c": Double(top.confidence),
        ])
    }
    return ["path": path, "text": lines.joined(separator: "\n"),
            "lines": lines.count, "width": Int(w), "height": Int(h),
            "confidence": lines.isEmpty ? 0 : Double(conf / Float(lines.count)),
            "boxes": boxes]
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: ocr <image>\n".data(using: .utf8)!)
    exit(2)
}
for p in args {
    if let d = try? JSONSerialization.data(withJSONObject: recognize(p)),
       let s = String(data: d, encoding: .utf8) { print(s) }
}
