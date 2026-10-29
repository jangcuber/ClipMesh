import Foundation
import CoreGraphics
import ImageIO
func pixels(_ path: String) throws -> (Int, Int, Data) {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    guard bytes.count <= 1048576, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, width <= 256, height > 0, height <= 256,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "OwnedPNG", code: 1) }
    var result = Data(count: width * height * 4)
    let rendered = result.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
    }
    guard rendered else { throw NSError(domain: "OwnedPNG", code: 2) }
    return (width, height, result)
}
guard CommandLine.arguments.count == 3 else { exit(64) }
let first = try pixels(CommandLine.arguments[1]), second = try pixels(CommandLine.arguments[2])
let equal = first.0 == second.0 && first.1 == second.1 && first.2 == second.2
print("{\"matches_expected_pixels\":\(equal)}")
exit(equal ? 0 : 1)
