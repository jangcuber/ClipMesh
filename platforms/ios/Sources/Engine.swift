import UIKit
import Foundation

@_silgen_name("ClipMeshReadClipboard")
private func readClipboardFromHelper() -> UnsafeMutablePointer<CChar>?

/// Protocol state is main-queue confined; UIPasteboard access is isolated on a serial worker.
final class ClipboardEngine: NSObject {
    static let shared = ClipboardEngine()
    private var config = Configuration()
    private var group: Group?
    private var metadata = EngineState()
    private var socket: MeshSocket?
    private var timer: Timer?
    private let clipboardQueue = DispatchQueue(label: "dev.clipmesh.clipboard", qos: .utility)
    private var lastChange = 0 // clipboardQueue only
    private var pollBusy = false // main queue only
    private var diagnostics: [String: Int] = [:] // Counts only: never contents, hashes or keys.
    private var lastStatusWrite = Date.distantPast
    private var configData: Data?
    private var pending: ClipEvent?
    private var connected = false
    private var transport = ""
    private var peerStatus: [String: Any] = [:]
    private var clipboardEpoch = 0 // main-queue revision: invalidate reads overtaken by remote copies
    private var generation = 0
    private var nextConnect = Date.distantPast
    private var backoff: TimeInterval = 1
    private var lastPing = Date.distantPast
    private var status = "Not paired"

    func start() {
        guard timer == nil else { return }
        if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(EngineState.self, from: data) { metadata = state }
        resetClipboardBaseline()
        refreshConfiguration()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func refreshConfiguration() {
        guard let data = try? Data(contentsOf: configurationURL) else {
            if configData != nil {
                configData = nil; generation += 1
                config.paused = true; group = nil; pending = nil
                socket?.cancel(); socket = nil; connected = false; transport = ""; peerStatus = [:]
                publish("Not paired")
            }
            return
        }
        guard data != configData else { return }
        configData = data
        let loaded = Configuration.load()
        let next = loaded.active
        let changed = next != group || loaded.paused != config.paused || loaded.device != config.device
        config = loaded
        group = next
        let retainedIds = Set(loaded.groups.map { $0.id })
        let oldCount = metadata.groups.count
        metadata.groups = metadata.groups.filter { retainedIds.contains($0.key) }
        if metadata.groups.count != oldCount { persist() }
        if changed {
            generation += 1
            socket?.cancel()
            socket = nil; connected = false; transport = ""; peerStatus = [:]; pending = nil
            resetClipboardBaseline()
            backoff = 1; nextConnect = .distantPast
            publish(config.paused ? "Paused" : group == nil ? "Not paired" : "Connecting")
        }
    }
    private func tick() {
        diagnostics["ticks", default: 0] += 1
        refreshConfiguration()
        if Date().timeIntervalSince(lastStatusWrite) >= 2 { publish(status, force: true) }
        guard !config.paused, let group else { return }
        if socket == nil && Date() >= nextConnect { connect(group) }
        pollClipboard(group: group)
        if connected && Date().timeIntervalSince(lastPing) > 20, let current = socket {
            lastPing = Date()
            current.ping { [weak self, weak current] error in
                DispatchQueue.main.async { guard let self, self.socket === current else { return }; if error != nil { self.disconnected() } }
            }
        }
    }
    private func resetClipboardBaseline() {
        clipboardQueue.async { [weak self] in
            self?.lastChange = UIPasteboard.general.changeCount
        }
    }
    private func pollClipboard(group: Group) {
        guard !pollBusy else { return }
        pollBusy = true
        diagnostics["poll_started", default: 0] += 1
        let captured = generation
        let capturedEpoch = clipboardEpoch
        clipboardQueue.async { [weak self] in
            guard let self else { return }
            let board = UIPasteboard.general
            let count = board.changeCount
            let changed = count != self.lastChange
            self.lastChange = count
            // Publish the read-start stage before the potentially blocking string call.
            DispatchQueue.main.async {
                self.diagnostics["observed_change_count"] = count
                self.diagnostics["poll_count_completed", default: 0] += 1
                if changed { self.diagnostics["change_observed", default: 0] += 1; self.diagnostics["read_started", default: 0] += 1 }
            }
            var text: String?
            var mime = "text/plain"
            var helperFailed = false
            if changed {
                if let raw = readClipboardFromHelper() {
                    defer { free(raw) }
                    let bytes = Data(bytes: raw, count: strlen(raw))
                    if let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                       let observed = result["change_count"] as? Int, observed == count {
                        text = result["text"] as? String
                        mime = result["mime"] as? String ?? "text/plain"
                    } else { helperFailed = true }
                } else { helperFailed = true }
                // Transient snapshot races or failed helpers must retry, not lose a copy.
                if helperFailed { self.lastChange = count - 1 }
            }
            let hasStrings = text != nil
            DispatchQueue.main.async {
                self.pollBusy = false
                self.diagnostics["poll_completed", default: 0] += 1
                guard captured == self.generation, !self.config.paused, self.group?.id == group.id else { return }
                guard capturedEpoch == self.clipboardEpoch else { self.diagnostics["stale_reads_dropped", default: 0] += 1; return }
                if changed {
                    if helperFailed { self.diagnostics["helper_failed", default: 0] += 1 }
                    self.diagnostics["read_completed", default: 0] += 1
                    self.diagnostics[hasStrings ? "has_strings" : "no_strings", default: 0] += 1
                    if text == nil { self.diagnostics["nil_reads", default: 0] += 1 }
                    if let text { self.localCopy(text, mime: mime, group: group) }
                }
            }
        }
    }
    private func localCopy(_ text: String, mime: String, group: Group) {
        guard mime != "text/plain" || !text.contains("clipmesh://join#") else { diagnostics["pairing_filtered", default: 0] += 1; return }
        var state = metadata.groups[group.id] ?? GroupState()
        guard state.clock < maxClock - 1 else { publish("Clock exhausted; create a new group"); return }
        state.clock += 1
        let event = ClipEvent(id: UUID().uuidString.lowercased(), device: config.device, clock: state.clock, created_ms: UInt64(Date().timeIntervalSince1970 * 1000), mime: mime, text: text)
        do {
            _ = try state.observe(event, group: group)
            metadata.groups[group.id] = state
            persist()
            diagnostics["local_events", default: 0] += 1
            pending = event
            flush()
        } catch { publish("Unable to encrypt clipboard") }
    }
    private func connect(_ group: Group) {
        do { try group.validate() } catch { publish("Invalid group configuration"); nextConnect = Date().addingTimeInterval(60); return }
        let task = MeshSocket(group: group)
        let captured = generation
        socket = task
        task.onOpen = { [weak self, weak task] in
            guard let self, self.socket === task, self.generation == captured else { return }
            self.connected = true; self.backoff = 1; self.lastPing = Date()
            // Publish the authenticated saved group winner, never the pre-existing
            // system clipboard. This repairs convergence after a relay restart.
            if let winner = try? self.metadata.groups[group.id]?.winningEvent(group: group),
               self.pending == nil || self.pending!.order < winner.order {
                self.pending = winner
            }
            self.publish("Connected"); self.flush()
        }
        task.onStatus = { [weak self, weak task] mode, connected in
            guard let self, self.socket === task, self.generation == captured else { return }
            self.connected = connected
            self.transport = mode
            self.publish(!connected ? "Offline · retrying" : mode == "p2p-direct" ? "Connected · direct P2P" : mode == "iroh-relay" ? "Connected · encrypted relay" : "Connected · " + mode)
        }
        task.onPeerStatus = { [weak self, weak task] details in
            guard let self, self.socket === task, self.generation == captured else { return }
            self.peerStatus = details
            self.rememberSeeds(details)
            self.publish(self.status, force: true)
        }
        task.onClose = { [weak self, weak task] in
            guard let self, self.socket === task, self.generation == captured else { return }
            self.disconnected()
        }
        task.onMessage = { [weak self, weak task] data in
            guard let self, self.socket === task, self.generation == captured else { return }
            self.accept(data)
        }
        task.start()
        publish("Connecting")
    }
    private func accept(_ data: Data) {
        guard !config.paused, let group else { return }
        do {
            let event = try Wire.open(data, group: group)
            var state = metadata.groups[group.id] ?? GroupState()
            let wins = try state.observe(event, group: group)
            metadata.groups[group.id] = state
            persist()
            guard wins, event.device != config.device else { return }
            if let queued = pending, queued.order <= event.order { pending = nil }
            clipboardEpoch += 1
            let capturedGeneration = generation
            diagnostics["remote_apply_started", default: 0] += 1
            clipboardQueue.async { [weak self] in
                guard let self else { return }
                let image = event.mime == "image/png" ? Data(base64Encoded: event.text).flatMap { UIImage(data: $0) } : nil
                if event.mime == "image/png" && image == nil {
                    DispatchQueue.main.async { self.diagnostics["invalid_images", default: 0] += 1 }; return
                }
                // A queued old-group write must not apply after pause, switch or engine reload.
                var allowed = false
                DispatchQueue.main.sync { allowed = self.generation == capturedGeneration && !self.config.paused && self.group?.id == group.id }
                guard allowed else { return }
                let board = UIPasteboard.general
                if let image { board.image = image } else { board.string = event.text }
                self.lastChange = board.changeCount // Consume own native write: no echo.
                DispatchQueue.main.async { self.diagnostics["remote_apply_completed", default: 0] += 1 }
            }
        } catch {
            publish("Connected · rejected invalid message") // Never log keys, clipboard data, or decoded payloads.
        }
    }
    private func flush() {
        guard connected, let task = socket, let group, let event = pending else { return }
        do {
            let bytes = try Wire.seal(event, group: group)
            pending = nil
            let capturedGeneration = generation
            diagnostics["send_started", default: 0] += 1
            task.send(bytes) { [weak self, weak task] error in
                DispatchQueue.main.async {
                    guard let self, let task, self.generation == capturedGeneration else { return }
                    self.diagnostics[error == nil ? "send_completed" : "send_failed", default: 0] += 1
                    if error != nil {
                        let latest = self.metadata.groups[group.id]?.latest
                        if (latest == nil || latest! <= event.order) && (self.pending == nil || self.pending!.order < event.order) { self.pending = event }
                        if self.socket === task { self.disconnected() }
                    }
                }
            }
        } catch { publish("Unable to encrypt clipboard") }
    }
    /// Persist public discovery IDs only; never overwrite a newer external configuration.
    private func rememberSeeds(_ details: [String: Any]) {
        guard let current = group, current.transport == "p2p", let advertised = details["seed_ids"] as? [String],
              let own = details["self_id"] as? String, Group.validSeed(own),
              let disk = try? Data(contentsOf: configurationURL), disk == configData,
              let index = config.groups.firstIndex(where: { $0.id == current.id }) else { return }
        var identifiers: [String] = []
        for value in [own] + advertised + current.seeds where Group.validSeed(value) && !identifiers.contains(value) {
            identifiers.append(value); if identifiers.count == 32 { break }
        }
        guard identifiers != config.groups[index].seeds else { return }
        var next = config; next.groups[index].seeds = identifiers
        do {
            let bytes = try JSONEncoder().encode(next)
            try secureWrite(bytes, to: configurationURL)
            config = next; group = next.active; configData = bytes
        } catch { /* Retain the running connection; retry public metadata persistence later. */ }
    }
    private func disconnected() {
        connected = false; transport = ""; peerStatus = [:]
        let old = socket; socket = nil
        old?.cancel()
        nextConnect = Date().addingTimeInterval(backoff + Double.random(in: 0...0.5))
        backoff = min(backoff * 2, 30)
        publish("Offline · retrying")
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(metadata) { try? secureWrite(data, to: stateURL) }
    }
    private func publish(_ message: String, force: Bool = false) {
        guard force || status != message else { return }
        status = message
        lastStatusWrite = Date()
        var value: [String: Any] = ["status": message, "updated_ms": UInt64(Date().timeIntervalSince1970 * 1000), "group": group?.name ?? "", "group_id": group?.id ?? "", "device": config.device, "diagnostics": diagnostics, "poll_busy": pollBusy, "engine_version": "0.3.0", "transport": transport, "clipboard_backend": "scoped-helper"]
        for (key, field) in peerStatus { value[key] = field }
        if let data = try? JSONSerialization.data(withJSONObject: value) { try? secureWrite(data, to: statusURL) }
    }
}

@_cdecl("ClipMeshStart")
public func ClipMeshStart() {
    guard Bundle.main.bundleIdentifier == "com.apple.springboard" else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { ClipboardEngine.shared.start() }
}
