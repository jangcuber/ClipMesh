import Foundation

@main struct TransportCheck {
    static func main() throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let port = Int.random(in: 43000...55000)
        func startRelay() throws -> Process {
            let process = Process(); process.executableURL = binary; process.arguments = ["relay", "--listen", "127.0.0.1:\(port)"]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            Thread.sleep(forTimeInterval: 0.25)
            return process
        }
        var relay = try startRelay()
        defer { if relay.isRunning { relay.terminate(); relay.waitUntilExit() } }
        guard relay.isRunning else { throw ClipError.invalid("Relay failed to start") }
        let group = Group(name: "Native transport test", relay: "ws://127.0.0.1:\(port)", key: Data(repeating: 7, count: 32).base64EncodedString())
        let sender = MeshSocket(url: group.endpoint), receiver = MeshSocket(url: group.endpoint)
        var opens = 0, done = false, failure: Error?
        var event = ClipEvent(id: UUID().uuidString.lowercased(), device: UUID().uuidString.lowercased(), clock: 1, created_ms: 1, mime: "text/plain", text: "Native Network.framework ↔ Rust relay ✅")
        let opened = {
            opens += 1
            if opens == 2 {
                do { sender.send(try Wire.seal(event, group: group)) { if let error = $0 { failure = error; done = true } } }
                catch { failure = error; done = true }
            }
        }
        sender.onOpen = opened; receiver.onOpen = opened
        sender.onClose = { failure = ClipError.invalid("Sender connection closed"); done = true }
        receiver.onClose = { failure = ClipError.invalid("Receiver connection closed"); done = true }
        receiver.onMessage = { data in
            do { let received = try Wire.open(data, group: group); precondition(received.text == event.text); done = true }
            catch { failure = error; done = true }
        }
        sender.start(); receiver.start()
        let deadline = Date().addingTimeInterval(10)
        while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        sender.cancel(); receiver.cancel()
        if let failure { throw failure }
        guard done else { throw ClipError.invalid("Native transport test timed out") }
        // Exercise the exact same native transport with binary PNG content.
        let imageSender = MeshSocket(url: group.endpoint), imageReceiver = MeshSocket(url: group.endpoint)
        opens = 0; done = false; failure = nil
        event.mime = "image/png"
        event.text = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg=="
        event.clock += 1; event.id = UUID().uuidString.lowercased()
        let imageOpen = {
            opens += 1
            if opens == 2 {
                do { imageSender.send(try Wire.seal(event, group: group)) { if let error = $0 { failure = error; done = true } } }
                catch { failure = error; done = true }
            }
        }
        imageSender.onOpen = imageOpen; imageReceiver.onOpen = imageOpen
        imageSender.onClose = { failure = ClipError.invalid("Image sender closed"); done = true }
        imageReceiver.onClose = { failure = ClipError.invalid("Image receiver closed"); done = true }
        imageReceiver.onMessage = { data in
            // The relay may replay the earlier text before the new image.
            do { let received = try Wire.open(data, group: group); if received.id == event.id { precondition(received.mime == "image/png" && received.text == event.text); done = true } }
            catch { failure = error; done = true }
        }
        imageSender.start(); imageReceiver.start()
        let imageDeadline = Date().addingTimeInterval(10)
        while !done && Date() < imageDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        imageSender.cancel(); imageReceiver.cancel()
        if let failure { throw failure }
        guard done else { throw ClipError.invalid("Image transport timed out") }
        // Save only ciphertext, destroy both client connections and the relay,
        // then recover a new process state and publish its saved winner.
        var state = GroupState()
        _ = try state.observe(event, group: group)
        let disk = try JSONEncoder().encode(EngineState(groups: [group.id: state]))
        relay.terminate(); relay.waitUntilExit()
        relay = try startRelay()
        guard relay.isRunning else { throw ClipError.invalid("Relay restart failed") }
        let recoveredState = try JSONDecoder().decode(EngineState.self, from: disk)
        let winner = try recoveredState.groups[group.id]!.winningEvent(group: group)!
        let rejoined = MeshSocket(url: group.endpoint), newcomer = MeshSocket(url: group.endpoint)
        opens = 0; done = false; failure = nil
        let recoveredOpen = {
            opens += 1
            if opens == 2 {
                do { rejoined.send(try Wire.seal(winner, group: group)) { if let error = $0 { failure = error; done = true } } }
                catch { failure = error; done = true }
            }
        }
        rejoined.onOpen = recoveredOpen; newcomer.onOpen = recoveredOpen
        rejoined.onClose = { failure = ClipError.invalid("Rejoined connection closed"); done = true }
        newcomer.onClose = { failure = ClipError.invalid("Newcomer connection closed"); done = true }
        newcomer.onMessage = { data in
            do { let received = try Wire.open(data, group: group); precondition(received.text == event.text && received.order == event.order); done = true }
            catch { failure = error; done = true }
        }
        rejoined.start(); newcomer.start()
        let recoveryDeadline = Date().addingTimeInterval(10)
        while !done && Date() < recoveryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        rejoined.cancel(); newcomer.cancel()
        if let failure { throw failure }
        guard done else { throw ClipError.invalid("Winner recovery transport test timed out") }
        // Test the production anonymous-pipe C bridge without touching iOS paths.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func configFile(_ name: String) throws -> String {
            let url = directory.appendingPathComponent(name + ".json")
            let config = Configuration(device: UUID().uuidString.lowercased(), name: name, groups: [group], active_group: group.id, paused: false)
            try secureWrite(JSONEncoder().encode(config), to: url)
            return url.path
        }
        let first = NativeTransport(executablePath: binary.path, configPath: try configFile("first"))
        let second = NativeTransport(executablePath: binary.path, configPath: try configFile("second"))
        opens = 0; done = false; failure = nil
        let bridgeOpen = {
            opens += 1
            if opens == 2 {
                do { first.send(try Wire.seal(event, group: group)) { if let error = $0 { failure = error; done = true } } }
                catch { failure = error; done = true }
            }
        }
        first.onOpen = bridgeOpen; second.onOpen = bridgeOpen
        first.onClose = { failure = ClipError.invalid("First native helper closed"); done = true }
        second.onClose = { failure = ClipError.invalid("Second native helper closed"); done = true }
        second.onMessage = { data in
            do { let received = try Wire.open(data, group: group); if received.id == event.id { precondition(received.mime == "image/png" && received.text == event.text); done = true } }
            catch { failure = error; done = true }
        }
        first.start(); second.start()
        let bridgeDeadline = Date().addingTimeInterval(20)
        while !done && Date() < bridgeDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        first.cancel(); second.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        if let failure { throw failure }
        guard done else { throw ClipError.invalid("Native helper pipe test timed out") }
        print("PASS: native peers exchange AES-GCM text and PNG via Rust relay; encrypted winner survives client/relay restart and converges a newly joined peer; production C/Swift subprocess bridge exchanges encrypted PNG")
    }
}
