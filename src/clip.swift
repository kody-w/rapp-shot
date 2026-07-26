// rapp-shot clipboard shim — put an image or text on the pasteboard.
// usage: clip image <file>   |   clip text <file>
import Foundation
import AppKit

let a = Array(CommandLine.arguments.dropFirst())
guard a.count == 2 else {
    FileHandle.standardError.write("usage: clip image|text <file>\n".data(using: .utf8)!); exit(2)
}
let pb = NSPasteboard.general
pb.clearContents()
switch a[0] {
case "image":
    guard let img = NSImage(contentsOfFile: a[1]) else {
        FileHandle.standardError.write("cannot read \(a[1])\n".data(using: .utf8)!); exit(1)
    }
    pb.writeObjects([img])
    print("{\"copied\":\"image\",\"file\":\"\(a[1])\"}")
case "text":
    guard let s = try? String(contentsOfFile: a[1], encoding: .utf8) else {
        FileHandle.standardError.write("cannot read \(a[1])\n".data(using: .utf8)!); exit(1)
    }
    pb.setString(s, forType: .string)
    print("{\"copied\":\"text\",\"chars\":\(s.count)}")
default:
    FileHandle.standardError.write("unknown mode \(a[0])\n".data(using: .utf8)!); exit(2)
}
