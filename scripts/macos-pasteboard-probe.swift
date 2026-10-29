import AppKit
let args = CommandLine.arguments
if args.count != 4 { fatalError("write/read NAME PATH") }
let board = NSPasteboard(name: NSPasteboard.Name(args[2]))
if args[1] == "write" {
    let data = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    board.clearContents()
    guard board.setData(data, forType: .png) else { exit(1) }
} else if args[1] == "read" {
    guard let data = board.data(forType: .png) else { exit(2) }
    try data.write(to: URL(fileURLWithPath: args[3]))
} else { fatalError("unknown action") }
