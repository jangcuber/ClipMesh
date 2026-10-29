import Foundation
import Network

/// Network.framework WebSocket transport. Unlike URL Loading System policy inherited
/// from SpringBoard, the transport explicitly supports the group's ws/wss endpoint.
final class MeshSocket {
    private var connection: NWConnection?
    private var native: NativeTransport?
    var onStatus: ((String, Bool) -> Void)?
    var onPeerStatus: (([String: Any]) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    private var closed = false
    private var notified = false
    private var nativeOfflineTimer: DispatchWorkItem?
    private var nativeOfflineTimeout: TimeInterval = 12
    private var fellBack = false
    init(url: URL?) {
        guard let url else { return }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }
    convenience init(group: Group, nativeExecutable: String = "/var/jb/usr/libexec/clipmesh-transport", nativeConfiguration: String = configurationURL.path, nativeOfflineTimeout: TimeInterval = 12) {
        self.init(url: group.endpoint)
        self.nativeOfflineTimeout = nativeOfflineTimeout
        if group.transport == "p2p" { native = NativeTransport(executablePath: nativeExecutable, configPath: nativeConfiguration) }
    }
    private func cancelNativeDeadline() { nativeOfflineTimer?.cancel(); nativeOfflineTimer = nil }
    private func armNativeDeadline() {
        // A relay-free group must keep its QUIC discovery alive. There is no WebSocket to fall back to.
        guard connection != nil, nativeOfflineTimer == nil, let current = native else { return }
        let timer = DispatchWorkItem { [weak self, weak current] in
            guard let self, let current, !self.closed, self.native === current else { return }
            self.fallbackToWebSocket(current)
        }
        nativeOfflineTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + nativeOfflineTimeout, execute: timer)
    }
    private func fallbackToWebSocket(_ current: NativeTransport) {
        guard !closed, native === current else { return }
        cancelNativeDeadline(); current.cancel(); native = nil
        guard connection != nil else { onStatus?("unavailable", false); fail(); return }
        fellBack = true
        onPeerStatus?([:])
        onStatus?("websocket-fallback", false)
        start()
    }
    func start() {
        if let native {
            native.onOpen = { [weak self, weak native] in
                guard let self, let native, !self.closed, self.native === native else { return }
                self.cancelNativeDeadline()
                self.onOpen?()
            }
            native.onClose = { [weak self, weak native] in
                guard let self, let native, !self.closed, self.native === native else { return }
                // A missing/unavailable native endpoint must not disable a working legacy relay.
                self.fallbackToWebSocket(native)
            }
            native.onMessage = { [weak self, weak native] data in
                guard let self, let native, !self.closed, self.native === native else { return }
                self.onMessage?(data)
            }
            native.onStatus = { [weak self, weak native] mode, connected in
                guard let self, let native, !self.closed, self.native === native else { return }
                if connected { self.cancelNativeDeadline() } else { self.armNativeDeadline() }
                self.onStatus?(mode, connected)
            }
            native.onPeerStatus = { [weak self, weak native] details in
                guard let self, let native, !self.closed, self.native === native else { return }
                self.onPeerStatus?(details)
            }
            armNativeDeadline()
            native.start(); return
        }
        guard connection != nil else { onStatus?("unavailable", false); fail(); return }
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.onOpen?(); self.onStatus?(self.fellBack ? "websocket-fallback" : "websocket", true); self.receive()
            case .failed, .cancelled, .waiting: self.fail()
            default: break
            }
        }
        connection?.start(queue: .main)
    }
    func cancel() { closed = true; cancelNativeDeadline(); connection?.cancel(); native?.cancel() }
    func send(_ bytes: Data, completion: @escaping (Error?) -> Void) {
        if let native { native.send(bytes, completion: completion) } else { send(bytes, opcode: .text, completion: completion) }
    }
    func ping(completion: @escaping (Error?) -> Void) {
        if native != nil { completion(nil) } else { send(Data(), opcode: .ping, completion: completion) }
    }
    private func send(_ bytes: Data, opcode: NWProtocolWebSocket.Opcode, completion: @escaping (Error?) -> Void) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "clipmesh", metadata: [metadata])
        connection?.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { error in completion(error) })
    }
    private func receive() {
        connection?.receiveMessage { [weak self] data, context, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.fail(); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if metadata.opcode == .close { self.fail(); return }
                if metadata.opcode == .text || metadata.opcode == .binary, let data {
                    guard complete, data.count <= maxFrameBytes else { self.fail(); return }
                    self.onMessage?(data)
                }
            }
            self.receive()
        }
    }
    private func fail() {
        guard !notified else { return }
        notified = true
        connection?.cancel()
        onClose?()
    }
}
