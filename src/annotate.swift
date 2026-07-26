// rapp-shot annotation renderer — CoreGraphics, on-device, no dependencies.
//
// usage: annotate <spec.json>
//   { "in": "src.png", "out": "dst.png", "ops": [ … ] }
//
// ops (all coordinates are TOP-LEFT pixel origin, matching the OCR shim):
//   {"op":"box",       "x","y","w","h", "color":"#ff3b30", "width":4}
//   {"op":"arrow",     "x1","y1","x2","y2", "color", "width"}
//   {"op":"text",      "x","y", "t":"…", "size":28, "color", "bg":"#000000cc"}
//   {"op":"highlight", "x","y","w","h", "color":"#ffe60066"}
//   {"op":"redact",    "x","y","w","h"}          opaque fill — irreversible
//   {"op":"pixelate",  "x","y","w","h", "scale":18}
//   {"op":"crop",      "x","y","w","h"}          applied first, shifts later ops
//
// REDACTION IS OPAQUE ON PURPOSE. Blur and pixelation are reversible often
// enough to have leaked real secrets in public, so `redact` paints a solid
// rectangle. `pixelate` exists for cosmetic de-emphasis and says so.
import Foundation
import AppKit
import CoreImage

func hexColor(_ s: String?, _ fallback: NSColor) -> NSColor {
    guard var h = s, h.hasPrefix("#") else { return fallback }
    h.removeFirst()
    guard let v = UInt64(h, radix: 16) else { return fallback }
    let hasAlpha = h.count == 8
    let r, g, b, a: CGFloat
    if hasAlpha {
        r = CGFloat((v >> 24) & 0xff) / 255; g = CGFloat((v >> 16) & 0xff) / 255
        b = CGFloat((v >> 8) & 0xff) / 255;  a = CGFloat(v & 0xff) / 255
    } else {
        r = CGFloat((v >> 16) & 0xff) / 255; g = CGFloat((v >> 8) & 0xff) / 255
        b = CGFloat(v & 0xff) / 255;         a = 1
    }
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func num(_ d: [String: Any], _ k: String, _ dflt: CGFloat = 0) -> CGFloat {
    if let v = d[k] as? Double { return CGFloat(v) }
    if let v = d[k] as? Int { return CGFloat(v) }
    return dflt
}

let args = Array(CommandLine.arguments.dropFirst())
guard let specPath = args.first,
      let raw = FileManager.default.contents(atPath: specPath),
      let spec = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
      let inPath = spec["in"] as? String, let outPath = spec["out"] as? String else {
    FileHandle.standardError.write("usage: annotate <spec.json>\n".data(using: .utf8)!)
    exit(2)
}
guard let src = NSImage(contentsOfFile: inPath),
      var cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(inPath)\n".data(using: .utf8)!)
    exit(1)
}
let ops = (spec["ops"] as? [[String: Any]]) ?? []

// crop first so later ops address the cropped image
var offX: CGFloat = 0, offY: CGFloat = 0
for o in ops where (o["op"] as? String) == "crop" {
    let r = CGRect(x: num(o, "x"), y: num(o, "y"), width: num(o, "w"), height: num(o, "h"))
    if let c = cg.cropping(to: r) { cg = c; offX = r.minX; offY = r.minY }
}

let W = cg.width, H = cg.height
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("cannot create context\n".data(using: .utf8)!); exit(1)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

// caller works in top-left origin; CoreGraphics is bottom-left
func flip(_ y: CGFloat, _ h: CGFloat) -> CGFloat { CGFloat(H) - y - h }

let ciCtx = CIContext()

for o in ops {
    let kind = (o["op"] as? String) ?? ""
    if kind == "crop" { continue }
    let x = num(o, "x") - offX, y = num(o, "y") - offY
    let w = num(o, "w"), h = num(o, "h")
    let rect = CGRect(x: x, y: flip(y, h), width: w, height: h)
    let color = hexColor(o["color"] as? String, NSColor.systemRed)
    let lw = num(o, "width", 4)

    switch kind {
    case "box":
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(lw); ctx.stroke(rect)
    case "highlight":
        ctx.setFillColor(hexColor(o["color"] as? String,
                                  NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 0.4)).cgColor)
        ctx.fill(rect)
    case "redact":
        // opaque, irreversible — see the header note
        ctx.setFillColor(hexColor(o["color"] as? String, NSColor.black).cgColor)
        ctx.setAlpha(1.0); ctx.fill(rect)
    case "pixelate":
        let scale = max(2, num(o, "scale", 18))
        let ci = CIImage(cgImage: cg)
        let f = CIFilter(name: "CIPixellate")!
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: kCIInputCenterKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        if let out = f.outputImage,
           let px = ciCtx.createCGImage(out, from: CGRect(x: 0, y: 0, width: W, height: H)),
           let piece = px.cropping(to: rect) {
            ctx.draw(piece, in: rect)
        }
    case "arrow":
        let x1 = num(o, "x1") - offX, y1 = flip(num(o, "y1"), 0)
        let x2 = num(o, "x2") - offX, y2 = flip(num(o, "y2"), 0)
        ctx.setStrokeColor(color.cgColor); ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lw); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: x1, y: y1)); ctx.addLine(to: CGPoint(x: x2, y: y2)); ctx.strokePath()
        let ang = atan2(y2 - y1, x2 - x1), head = max(12, lw * 4)
        ctx.move(to: CGPoint(x: x2, y: y2))
        ctx.addLine(to: CGPoint(x: x2 - head * cos(ang - .pi/7), y: y2 - head * sin(ang - .pi/7)))
        ctx.addLine(to: CGPoint(x: x2 - head * cos(ang + .pi/7), y: y2 - head * sin(ang + .pi/7)))
        ctx.closePath(); ctx.fillPath()
    case "text":
        let s = (o["t"] as? String) ?? ""
        let size = num(o, "size", 28)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: hexColor(o["color"] as? String, NSColor.white),
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = str.size()
        let pad: CGFloat = 8
        let ty = flip(y, bounds.height)
        if let bg = o["bg"] as? String {
            ctx.setFillColor(hexColor(bg, NSColor.black.withAlphaComponent(0.75)).cgColor)
            ctx.fill(CGRect(x: x - pad, y: ty - pad/2,
                            width: bounds.width + pad*2, height: bounds.height + pad))
        }
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        str.draw(at: NSPoint(x: x, y: ty))
        NSGraphicsContext.restoreGraphicsState()
    default:
        FileHandle.standardError.write("unknown op: \(kind)\n".data(using: .utf8)!)
    }
    ctx.setAlpha(1.0)
}

guard let outCG = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: outCG)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? data.write(to: URL(fileURLWithPath: outPath))
let res: [String: Any] = ["out": outPath, "width": W, "height": H, "ops": ops.count]
if let d = try? JSONSerialization.data(withJSONObject: res),
   let s = String(data: d, encoding: .utf8) { print(s) }
