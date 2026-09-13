// Test-only image fixtures and pixel inspection. Never captures a screen or uses a clipboard.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum FixtureError: Error { case invalidArguments, imageFailure }

func positive(_ value: String) throws -> Int {
    guard let number = Int(value), (1...20_000).contains(number) else { throw FixtureError.invalidArguments }
    return number
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw FixtureError.invalidArguments }
    switch command {
    case "blank":
        guard args.count == 4 else { throw FixtureError.invalidArguments }
        let width = try positive(args[2]), height = try positive(args[3])
        guard width * height <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.imageFailure
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError.imageFailure }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.imageFailure
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.imageFailure }
        try (data as Data).write(to: URL(fileURLWithPath: args[1]), options: .withoutOverwriting)
    case "distinct":
        guard args.count == 6, let x = Int(args[2]), let y = Int(args[3]), x >= 0, y >= 0 else {
            throw FixtureError.invalidArguments
        }
        let width = try positive(args[4]), height = try positive(args[5])
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              x + width <= image.width, y + height <= image.height,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw FixtureError.imageFailure
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw FixtureError.imageFailure }
        var distinct: Set<UInt8> = []
        for row in 0..<height {
            for column in 0..<width { distinct.insert(data[row * context.bytesPerRow + column]) }
        }
        print(distinct.count)
    default:
        throw FixtureError.invalidArguments
    }
} catch {
    FileHandle.standardError.write(Data("fixture_image: \(error)\nUsage: blank output.png width height | distinct image.png x y width height\n".utf8))
    exit(2)
}
