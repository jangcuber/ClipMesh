import Foundation

@main struct FallbackCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw ClipError.invalid("Expected core and controlled offline helper") }
        let core = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let offline = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let port = Int.random(in: 43000...55000)
        let relay = Process(); relay.executableURL = core; relay.arguments = ["relay", "--listen", "127.0.0.1:\(port)"]
        relay.standardOutput = FileHandle.nullDevice; relay.standardError = FileHandle.nullDevice
        try relay.run(); defer { if relay.isRunning { relay.terminate(); relay.waitUntilExit() } }
        Thread.sleep(forTimeInterval: 0.25)
        guard relay.isRunning else { throw ClipError.invalid("Relay did not start") }
        let group = Group(name: "Controlled fallback", relay: "ws://127.0.0.1:\(port)", key: Data(repeating: 47, count: 32).base64EncodedString(), transport: "p2p")
        let configuration = directory.appendingPathComponent("config.json")
        let config = Configuration(device: UUID().uuidString.lowercased(), name: "Controlled fallback", groups: [group], active_group: group.id, paused: false)
        try secureWrite(JSONEncoder().encode(config), to: configuration)
        // Production timeout is 12 seconds. Use a 350ms dependency-injected deadline in this host regression.
        let sender = MeshSocket(group: group, nativeExecutable: offline.path, nativeConfiguration: configuration.path, nativeOfflineTimeout: 0.35)
        let receiver = MeshSocket(url: group.endpoint)
        var opens = 0, done = false, failure: Error?, sawFallback = false
        let started = Date()
        let event = ClipEvent(id: UUID().uuidString.lowercased(), device: config.device, clock: 1, created_ms: 1, mime: "image/png", text: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg==")
        let opened = {
            opens += 1
            if opens == 2 {
                do { sender.send(try Wire.seal(event, group: group)) { if let error = $0 { failure = error; done = true } } }
                catch { failure = error; done = true }
            }
        }
        sender.onOpen = opened; receiver.onOpen = opened
        sender.onStatus = { route, _ in if route == "websocket-fallback" { sawFallback = true } }
        sender.onClose = { failure = ClipError.invalid("Fallback sender closed"); done = true }
        receiver.onClose = { failure = ClipError.invalid("Fallback receiver closed"); done = true }
        receiver.onMessage = { data in
            do { let received = try Wire.open(data, group: group); precondition(received.mime == event.mime && received.text == event.text); done = true }
            catch { failure = error; done = true }
        }
        sender.start(); receiver.start()
        let deadline = Date().addingTimeInterval(5)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        sender.cancel(); receiver.cancel(); RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        if let failure { throw failure }
        guard done, sawFallback, Date().timeIntervalSince(started) < 4 else { throw ClipError.invalid("Offline helper did not fall back within a bounded deadline") }
        // Serverless groups must retain native retries instead of attempting an absent URL.
        var automatic = group; automatic.relay = ""
        let retrying = MeshSocket(group: automatic, nativeExecutable: offline.path, nativeConfiguration: configuration.path, nativeOfflineTimeout: 0.1)
        var invalidFallback = false, closedServerless = false
        retrying.onStatus = { mode, _ in if mode.contains("websocket") { invalidFallback = true } }
        retrying.onClose = { closedServerless = true }
        retrying.start(); RunLoop.current.run(until: Date().addingTimeInterval(0.4)); retrying.cancel()
        precondition(!invalidFallback && !closedServerless)
        print("PASS: live offline helper status spam cannot reset deadline; native WebSocket fallback delivers authenticated PNG; relay-free groups keep native retries without fabricating a URL")
    }
}
