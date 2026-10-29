import Foundation
import Darwin

@_silgen_name("ClipMeshTransportStart") private func transportStart(_ executable: UnsafePointer<CChar>, _ configuration: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("ClipMeshTransportFD") private func transportFD(_ process: UnsafeMutableRawPointer) -> Int32
@_silgen_name("ClipMeshTransportWrite") private func transportWrite(_ process: UnsafeMutableRawPointer, _ data: UnsafePointer<CChar>, _ count: Int) -> Int32
@_silgen_name("ClipMeshTransportStop") private func transportStop(_ process: UnsafeMutableRawPointer)

/// Rust's native iroh endpoint runs as a separate child of SpringBoard.
/// Only authenticated ciphertext crosses this anonymous-pipe bridge.
final class NativeTransport {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onPeerStatus: (([String: Any]) -> Void)?
    private let executablePath: String
    private let configPath: String
    init(executablePath: String = "/var/jb/usr/libexec/clipmesh-transport", configPath: String = configurationURL.path) {
        self.executablePath = executablePath; self.configPath = configPath
    }
    private let queue = DispatchQueue(label: "dev.clipmesh.transport", qos: .utility)
    private let writer = DispatchQueue(label: "dev.clipmesh.transport.writer", qos: .utility)
    private let processLock = NSLock()
    private var process: UnsafeMutableRawPointer? // writes/stop protected by processLock
    private var source: DispatchSourceRead? // queue confined
    private var buffer = Data() // queue confined
    private var closed = false // queue confined
    private var opened = false // main queue confined
    func start() {
        queue.async { [self] in
            guard !closed, process == nil else { return }
            let launched = executablePath.withCString { executable in configPath.withCString { config in transportStart(executable, config) } }
            guard let child = launched else { fail(); return }
            processLock.lock(); process = child; processLock.unlock()
            let source = DispatchSource.makeReadSource(fileDescriptor: transportFD(child), queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.resume()
        }
    }
    func send(_ bytes: Data, completion: @escaping (Error?) -> Void) {
        writer.async { [self] in
            guard let frame = String(data: bytes, encoding: .utf8), let line = try? JSONSerialization.data(withJSONObject: ["op": "send", "frame": frame], options: [.withoutEscapingSlashes]) else {
                DispatchQueue.main.async { completion(ClipError.invalid("Invalid transport frame")) }; return
            }
            // Reads run independently: simultaneous large copies cannot deadlock two full pipes.
            processLock.lock()
            guard let child = process else {
                processLock.unlock(); DispatchQueue.main.async { completion(ClipError.invalid("Transport closed")) }; return
            }
            var command = line; command.append(10)
            let result = command.withUnsafeBytes { raw in transportWrite(child, raw.baseAddress!.assumingMemoryBound(to: CChar.self), command.count) }
            processLock.unlock()
            DispatchQueue.main.async { completion(result == 0 ? nil : ClipError.invalid("Transport unavailable")) }
            if result != 0 { queue.async { [self] in fail() } }
        }
    }
    func cancel() { queue.async { [self] in stop() } }
    private func readAvailable() {
        guard !closed, let child = process else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(transportFD(child), &bytes, bytes.count)
            if count == 0 { fail(); return }
            if count < 0 { if errno != EAGAIN && errno != EINTR { fail() }; return }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= maxFrameBytes * 2 else { fail(); return }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                guard line.count <= maxFrameBytes * 2, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { fail(); return }
                if object["type"] as? String == "frame", let frame = object["frame"] as? String, frame.utf8.count <= maxFrameBytes {
                    let data = Data(frame.utf8); DispatchQueue.main.async { [weak self] in self?.onMessage?(data) }
                } else if object["type"] as? String == "status" {
                    let connected = object["connected"] as? Bool ?? false
                    let mode = object["transport"] as? String ?? "p2p"
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if connected && !self.opened { self.opened = true; self.onOpen?() }
                        if !connected { self.opened = false }
                        self.onStatus?(mode, connected)
                        let peerStatus: [String: Any] = ["connected_peer_count": object["connected_peer_count"] as? Int ?? object["peers"] as? Int ?? 0, "known_peer_count": object["known_peer_count"] as? Int ?? 0, "peer_details": object["peer_details"] as? [[String: Any]] ?? []]
                        var enriched = peerStatus
                        enriched["self_id"] = object["self_id"] as? String ?? ""
                        enriched["seed_ids"] = object["seed_ids"] as? [String] ?? []
                        self.onPeerStatus?(enriched)
                    }
                }
            }
        }
    }
    private func fail() { stop(); DispatchQueue.main.async { [weak self] in self?.onClose?() } }
    private func stop() {
        guard !closed else { return }; closed = true
        source?.cancel(); source = nil
        processLock.lock()
        if let child = process { process = nil; transportStop(child) }
        processLock.unlock()
        buffer.removeAll()
    }
}
