import AppKit
final class DelayedImage: NSObject, NSPasteboardItemDataProvider {
    let data: Data
    init(_ data: Data) { self.data = data }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // The producer publishes the promised image separately once ready.
    }
}
let args = CommandLine.arguments
if args.count != 4 { fatalError("write/read NAME PATH") }
let board = NSPasteboard(name: NSPasteboard.Name(args[2]))
if args[1] == "delayed" {
    let provider = DelayedImage(try Data(contentsOf: URL(fileURLWithPath: args[3])))
    let item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.png])
    item.setString("Image is still loading", forType: .string)
    board.clearContents()
    guard board.writeObjects([item]) else { exit(3) }
    print("ready"); fflush(stdout)
    let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
        board.setData(provider.data, forType: .png)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    timer.invalidate()
} else if ["write", "empty", "jpeg", "tiff", "mixed"].contains(args[1]) {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    board.clearContents()
    if args[1] == "empty" { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }
    if args[1] == "write" || args[1] == "empty" {
        guard board.setData(data, forType: .png) else { exit(1) }
    } else {
        guard let rep = NSBitmapImageRep(data: data) else { exit(3) }
        if args[1] == "tiff" {
            guard let encoded = rep.tiffRepresentation, board.setData(encoded, forType: .tiff) else { exit(3) }
        } else {
            let item = NSPasteboardItem()
            guard let encoded = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { exit(3) }
            item.setData(encoded, forType: NSPasteboard.PasteboardType("public.jpeg"))
            item.setString("Image description must not replace image", forType: .string)
            if args[1] == "mixed" { item.setData(Data("invalid png".utf8), forType: .png) }
            guard board.writeObjects([item]) else { exit(3) }
        }
    }
    // Large pasteboard transfers can still depend on their producer's IPC
    // endpoint. Keep the producer alive while the application reads the data.
    if data.count > 8 * 1024 * 1024 { RunLoop.current.run(until: Date().addingTimeInterval(5)) }
} else if args[1] == "read" {
    guard let data = board.data(forType: .png) else { exit(2) }
    try data.write(to: URL(fileURLWithPath: args[3]))
} else { fatalError("unknown action") }
