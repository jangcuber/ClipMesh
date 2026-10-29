import AppKit
import ImageIO

func bitmap(_ bytes: Data, expected: (Int, Int)? = nil) -> (Int, Int, Data)? {
    guard bytes.count <= 8 * 1024 * 1024, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 256, height <= 256 else { return nil }
    if let expected, width != expected.0 || height != expected.1 { return nil }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var output = Data(count: width * height * 4)
    let success = output.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return success ? (width, height, output) : nil
}
let args = CommandLine.arguments
if args.count != 3 || !["read", "write"].contains(args[1]) { exit(64) }
let path = URL(fileURLWithPath: args[2])
guard path.lastPathComponent.hasPrefix("ClipMesh-ImageTest-"), let expected = try? Data(contentsOf: path), let reference = bitmap(expected) else { exit(65) }
let board = NSPasteboard.general
if args[1] == "write" { board.clearContents(); guard board.setData(expected, forType: .png) else { exit(74) } }
let actual = board.data(forType: .png) ?? board.data(forType: .tiff)
let decoded = actual.flatMap { bitmap($0, expected: (reference.0, reference.1)) }
let result: [String: Any] = ["operation": args[1], "has_image": actual != nil, "matches_expected_pixels": decoded?.2 == reference.2, "matches_expected_png_bytes": actual == expected]
let json = try JSONSerialization.data(withJSONObject: result)
FileHandle.standardOutput.write(json + Data([10]))
