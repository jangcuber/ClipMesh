import AppKit
import CryptoKit
import ServiceManagement
import CoreImage
import ImageIO

struct Group: Codable {
    var name: String; var relay: String; var key: String; var transport: String? = nil; var seeds: [String]? = nil
    var id: String { SHA256.hash(data: Data(base64Encoded: key) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    var invitation: String {
        var value: [String: Any] = ["v": 1, "name": name, "relay": relay, "key": key]
        if let transport = transport { value["transport"] = transport }
        if let seeds = seeds, !seeds.isEmpty { value["seeds"] = Array(seeds.prefix(16)) }
        let data = try! JSONSerialization.data(withJSONObject: value)
        return "clipmesh://join#" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func parse(_ value: String) throws -> Group {
        guard value.utf8.count <= 8192, value.hasPrefix("clipmesh://join#") else { throw AppError.invalid("Expected a ClipMesh invitation link") }
        var base = String(value.dropFirst("clipmesh://join#".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base), let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], obj["v"] as? Int == 1,
              let name = obj["name"] as? String, let relay = obj["relay"] as? String, let key = obj["key"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200,
              Data(base64Encoded: key)?.count == 32 else { throw AppError.invalid("Invalid invitation or group key") }
        let transport = obj["transport"] as? String
        guard obj["transport"] == nil || obj["transport"] is NSNull || transport == "p2p" else { throw AppError.invalid("Unsupported group transport") }
        if relay.isEmpty {
            guard transport == "p2p" else { throw AppError.invalid("A relay is required for legacy mode") }
        } else {
            guard let url = URL(string: relay), ["ws", "wss"].contains(url.scheme ?? ""), url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { throw AppError.invalid("Invalid relay address") }
        }
        let seeds = obj["seeds"] as? [String]
        guard obj["seeds"] == nil || seeds != nil, (seeds?.count ?? 0) <= 32,
              seeds?.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true else { throw AppError.invalid("Invalid paired device identities") }
        return Group(name: name, relay: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")), key: key, transport: transport, seeds: seeds)
    }
}
struct Config: Codable {
    var v = 1; var device = UUID().uuidString.lowercased(); var name = Host.current().localizedName ?? "Mac"
    var groups: [Group] = []; var active_group = ""; var paused = false
}
enum AppError: LocalizedError { case invalid(String); var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil } }

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let fm = FileManager.default
    lazy var testPasteboardName: String? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--test-pasteboard"), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }()
    lazy var pasteboard: NSPasteboard = testPasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
    lazy var configURL: URL = {
        if let index = CommandLine.arguments.firstIndex(of: "--config"), CommandLine.arguments.indices.contains(index + 1) { return URL(fileURLWithPath: CommandLine.arguments[index + 1]) }
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--image-self-test") { return fm.temporaryDirectory.appendingPathComponent("clipmesh-smoke-" + UUID().uuidString).appendingPathComponent("config.json") }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipMesh/config.json")
    }()
    var config = Config()
    var child: Process?; var relayChild: Process?; var input: FileHandle?
    var statusItem: NSStatusItem!; var window: NSWindow!; var timer: Timer?
    var generation = UUID(); var lastChange = 0; var pendingRemote: (mime: String, value: String)?
    let groupPicker = NSPopUpButton(); let status = NSTextField(labelWithString: "No group selected")
    let relayField = NSTextField(string: "")
    let nameField = NSTextField(string: "My devices")
    let inviteField = NSTextField(string: "")
    let p2pToggle = NSButton(checkboxWithTitle: "Prefer P2P for this group (upgrade all devices first)", target: nil, action: nil)
    let hostToggle = NSButton(checkboxWithTitle: "Host a LAN relay on this Mac (port 47391)", target: nil, action: nil)
    let pauseToggle = NSButton(checkboxWithTitle: "클립보드 동기화 켜기", target: nil, action: nil)
    let loginToggle = NSButton(checkboxWithTitle: "로그인할 때 자동 실행 · 재부팅 후 연결 복구", target: nil, action: nil)
    var inviteDisplay: NSTextView!
    var advancedStack: NSStackView!
    let peersLabel = NSTextField(wrappingLabelWithString: "다른 기기를 찾는 중")
    var latestConnection: [String: Any] = [:]
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--enable-login-start") {
            do {
                try SMAppService.mainApp.register()
                let status = SMAppService.mainApp.status
                print(status == .enabled ? "login_start=enabled" : status == .requiresApproval ? "login_start=requiresApproval" : "login_start=unavailable")
                NSApp.terminate(nil); return
            } catch { fputs("Login startup registration failed\n", stderr); exit(1) }
        }
        do {
            try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: configURL.path) { config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL)) }
        } catch { alert(error) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⇄"
        let menu = NSMenu()
        menu.addItem(withTitle: "ClipMesh 열기…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "ClipMesh 완전히 종료", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        buildWindow(); refreshGroups()
        if CommandLine.arguments.contains("--image-self-test") {
            do { try imageSelfTest(); print("PASS native PNG pasteboard, TIFF conversion, limits, and QR round-trip"); NSApp.terminate(nil); return }
            catch { fputs("Image self-test failed: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            let check = Process(); let output = Pipe(); check.executableURL = coreURL; check.arguments = ["--version"]; check.standardOutput = output
            do {
                try check.run(); let version = output.fileHandleForReading.readDataToEndOfFile(); check.waitUntilExit()
                guard check.terminationStatus == 0, String(data: version, encoding: .utf8)?.contains("clipmesh ") == true, window.contentView != nil else { throw AppError.invalid("Bundled core failed smoke check") }
                try? fm.removeItem(at: configURL.deletingLastPathComponent())
                try dashboardSelfTest(); print("PASS dashboard counts, on/off state, hidden advanced settings, AppKit window and bundled Rust core")
                NSApp.terminate(nil); return
            } catch { fputs("Smoke test failed: \(error)\n", stderr); exit(1) }
        }
        hostToggle.state = UserDefaults.standard.bool(forKey: "hostRelay") ? .on : .off
        if hostToggle.state == .on && testPasteboardName == nil { startRelay() }
        lastChange = pasteboard.changeCount
        startCore()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            if self?.testPasteboardName != nil, let index = CommandLine.arguments.firstIndex(of: "--test-stop-file"), CommandLine.arguments.indices.contains(index + 1), FileManager.default.fileExists(atPath: CommandLine.arguments[index + 1]) { NSApp.terminate(nil); return }
            self?.pollClipboard()
        }
        if config.groups.isEmpty || CommandLine.arguments.contains("--show-settings") { showSettings() }
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 790), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ClipMesh · Account-free clipboard sync"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        window.contentView!.addSubview(scroll)
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)])
        func label(_ value: String) { let l = NSTextField(wrappingLabelWithString: value); stack.addArrangedSubview(l) }
        func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
        let heading = NSTextField(labelWithString: "ClipMesh"); heading.font = .boldSystemFont(ofSize: 28); stack.addArrangedSubview(heading)
        status.font = .boldSystemFont(ofSize: 20); status.lineBreakMode = .byWordWrapping; stack.addArrangedSubview(status)
        pauseToggle.font = .boldSystemFont(ofSize: 18); pauseToggle.target = self; pauseToggle.action = #selector(togglePause); stack.addArrangedSubview(pauseToggle)
        label("켜면 이 그룹의 텍스트와 이미지를 주고받습니다. 끄면 이 Mac의 송수신이 멈춥니다.")
        label("현재 그룹")
        groupPicker.target = self; groupPicker.action = #selector(selectGroup); stack.addArrangedSubview(groupPicker)
        peersLabel.font = .systemFont(ofSize: 14); stack.addArrangedSubview(peersLabel)
        peersLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let pairingButtons = NSStackView(views: [button("다른 기기 연결 · QR 표시", #selector(showQR)), button("QR 이미지로 참가", #selector(joinQR))]); stack.addArrangedSubview(pairingButtons)
        label("창을 닫아도 메뉴 막대 ⇄에서 계속 실행됩니다. 완전히 끝내려면 메뉴에서 종료하세요.")
        loginToggle.target = self; loginToggle.action = #selector(toggleLogin); loginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off; stack.addArrangedSubview(loginToggle)
        stack.addArrangedSubview(button("고급 설정 / 새 그룹 만들기 ▾", #selector(toggleAdvanced)))
        advancedStack = NSStackView(); advancedStack.orientation = .vertical; advancedStack.alignment = .leading; advancedStack.spacing = 10; advancedStack.isHidden = true; stack.addArrangedSubview(advancedStack)
        advancedStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        func advancedLabel(_ value: String) { advancedStack.addArrangedSubview(NSTextField(wrappingLabelWithString: value)) }
        p2pToggle.title = "직접 연결 우선 (P2P) · 연결이 어려우면 암호화 릴레이 사용"
        p2pToggle.target = self; p2pToggle.action = #selector(toggleP2P); advancedStack.addArrangedSubview(p2pToggle)
        advancedStack.addArrangedSubview(button("기존 그룹을 Mac 없이 연결로 전환", #selector(migrateStable)))
        advancedLabel("새 그룹 만들기 · 기존 기기와 연결하려면 위의 QR 참가를 사용하세요.")
        nameField.placeholderString = "그룹 이름"; relayField.placeholderString = "선택 사항 · 예전 WebSocket 릴레이 주소"
        for field in [nameField, relayField] { advancedStack.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: advancedStack.widthAnchor).isActive = true }
        hostToggle.title = "이 Mac에서 발견용 릴레이 실행 (포트 47391)"; hostToggle.target = self; hostToggle.action = #selector(toggleRelay); advancedStack.addArrangedSubview(hostToggle)
        advancedStack.addArrangedSubview(button("새 그룹 만들기", #selector(createGroup)))
        advancedLabel("초대 링크로 참가")
        inviteField.placeholderString = "clipmesh://join#…"; advancedStack.addArrangedSubview(inviteField); inviteField.widthAnchor.constraint(equalTo: advancedStack.widthAnchor).isActive = true
        advancedStack.addArrangedSubview(button("초대 링크로 참가", #selector(joinGroup)))
        advancedLabel("현재 그룹 초대 링크 · 비밀키가 포함되어 있습니다. 신뢰하는 기기에만 공유하세요.")
        let invitationScroll = NSScrollView(); invitationScroll.hasVerticalScroller = true
        inviteDisplay = NSTextView(); inviteDisplay.isEditable = false; inviteDisplay.isSelectable = true; inviteDisplay.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        invitationScroll.documentView = inviteDisplay; advancedStack.addArrangedSubview(invitationScroll)
        invitationScroll.widthAnchor.constraint(equalTo: advancedStack.widthAnchor).isActive = true; invitationScroll.heightAnchor.constraint(equalToConstant: 65).isActive = true
    }
    @objc func toggleAdvanced() { advancedStack.isHidden.toggle() }
    func renderConnection() {
        guard !config.groups.isEmpty else { status.stringValue = "먼저 기기를 연결하세요"; peersLabel.stringValue = "QR 이미지로 참가하거나 고급 설정에서 그룹을 만드세요."; pauseToggle.isEnabled = false; return }
        pauseToggle.isEnabled = true
        let ready = latestConnection["connected"] as? Bool ?? false
        let count = latestConnection["connected_peer_count"] as? Int ?? latestConnection["peers"] as? Int
        let mode = latestConnection["transport"] as? String ?? "websocket"
        let route = mode == "p2p-direct" ? "직접 연결" : mode == "iroh-relay" ? "암호화 릴레이" : "발견용 서버 연결"
        status.stringValue = config.paused ? "동기화 꺼짐" : !ready ? "연결 중…" : count == 0 ? "기기를 찾는 중…" : "동기화 켜짐 · " + route
        if let count {
            peersLabel.stringValue = "연결된 다른 기기 \(count)대 · 이 기기 포함 \(count + 1)대"
            if let details = latestConnection["peer_details"] as? [[String: Any]], !details.isEmpty {
                peersLabel.stringValue += "\n" + details.map { detail in
                    let name = (detail["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "이름 없는 기기"
                    let route = detail["route"] as? String == "direct" ? "직접" : detail["route"] as? String == "relay" ? "릴레이" : "경로 확인 중"
                    return "• " + name + " · " + route
                }.joined(separator: "\n")
            }
            if count == 0 { peersLabel.stringValue += "\n다른 기기에서 같은 그룹과 동기화 켜짐을 확인하세요." }
        } else { peersLabel.stringValue = ready ? "릴레이에 연결됨 · 개별 기기 수는 이 모드에서 확인할 수 없습니다." : "네트워크 연결을 기다리고 있습니다." }
        if config.paused { peersLabel.stringValue += "\n네트워크가 연결되어 있어도 클립보드는 보내거나 받지 않습니다." }
    }

    @objc func showSettings() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func quit() { NSApp.terminate(nil) }
    func alert(_ error: Error) { let a = NSAlert(error: error); a.runModal() }
    func save() throws { try JSONEncoder().encode(config).write(to: configURL, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path) }
    func refreshGroups() {
        groupPicker.removeAllItems(); groupPicker.addItems(withTitles: config.groups.map { $0.name })
        if let i = config.groups.firstIndex(where: { $0.id == config.active_group }) { groupPicker.selectItem(at: i); inviteDisplay.string = (try? sharingGroup().invitation) ?? "동기화를 켜면 연결용 QR이 준비됩니다." }
        else { inviteDisplay.string = "" }
        pauseToggle.state = config.paused ? .off : .on
        renderConnection()
        p2pToggle.state = config.groups.first(where: { $0.id == config.active_group })?.transport == "p2p" ? .on : .off
    }
    func add(_ group: Group) throws {
        if let index = config.groups.firstIndex(where: { $0.id == group.id }) { config.groups[index] = group } else { config.groups.append(group) }
        config.active_group = group.id; try save(); refreshGroups(); startCore()
    }
    @objc func createGroup() {
        do {
            var bytes = Data(count: 32)
            let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard result == errSecSuccess else { throw AppError.invalid("Secure random generation failed") }
            let group = Group(name: nameField.stringValue, relay: relayField.stringValue, key: bytes.base64EncodedString(), transport: "p2p")
            try add(Group.parse(group.invitation))
        } catch { alert(error) }
    }
    @objc func joinGroup() { do { try add(Group.parse(inviteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))); inviteField.stringValue = "" } catch { alert(error) } }
    @objc func selectGroup() { guard config.groups.indices.contains(groupPicker.indexOfSelectedItem) else { return }; config.active_group = config.groups[groupPicker.indexOfSelectedItem].id; do { try save(); refreshGroups(); startCore() } catch { alert(error) } }
    @objc func toggleP2P() {
        guard let index = config.groups.firstIndex(where: { $0.id == config.active_group }) else { return }
        if p2pToggle.state != .on && config.groups[index].relay.isEmpty { p2pToggle.state = .on; alert(AppError.invalid("이 그룹은 기기 간 자동 연결을 사용합니다. 동기화를 끄려면 위의 스위치를 사용하세요.")); return }
        config.groups[index].transport = p2pToggle.state == .on ? "p2p" : nil
        do { try save(); refreshGroups(); startCore() } catch { alert(error) }
    }
    @objc func togglePause() { config.paused = pauseToggle.state != .on; lastChange = pasteboard.changeCount; pendingRemote = nil; do { try save(); send(["op": "pause", "paused": config.paused]); renderConnection() } catch { alert(error) } }
    @objc func toggleLogin() {
        do { if loginToggle.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { loginToggle.state = .off; alert(error) }
    }
    @objc func toggleRelay() { UserDefaults.standard.set(hostToggle.state == .on, forKey: "hostRelay"); if hostToggle.state == .on && testPasteboardName == nil { startRelay() } else { relayChild?.terminate(); relayChild = nil } }
    var coreURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clipmesh-core") }
    func startRelay() {
        guard relayChild == nil else { return }
        let process = Process(); process.executableURL = coreURL; process.arguments = ["relay", "--listen", "0.0.0.0:47391"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in DispatchQueue.main.async { self?.relayChild = nil; if p.terminationStatus != 0 { self?.status.stringValue = "LAN relay failed. Port 47391 may already be in use." } } }
        do { try process.run(); relayChild = process } catch { alert(error) }
    }
    func stopCore() {
        generation = UUID(); input = nil
        if let child = child { child.terminationHandler = nil; child.terminate() }
        child = nil
    }
    func startCore() {
        stopCore(); latestConnection = [:]; renderConnection(); lastChange = pasteboard.changeCount; pendingRemote = nil
        guard !config.groups.isEmpty else { status.stringValue = "Create or join a group to start."; return }
        do { try save() } catch { alert(error); return }
        let token = generation, process = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.executableURL = coreURL; process.arguments = ["run", "--config", configURL.path]
        process.standardInput = stdinPipe; process.standardOutput = stdoutPipe; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in DispatchQueue.main.async { guard let self = self, self.generation == token else { return }; self.status.stringValue = "Sync engine stopped (\(p.terminationStatus)). Retrying…"; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in guard self?.generation == token else { return }; self?.startCore() } } }
        do {
            try process.run(); child = process; input = stdinPipe.fileHandleForWriting; status.stringValue = "Connecting…"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buffer = Data()
                while true {
                    let chunk = stdoutPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }; buffer.append(chunk)
                    if buffer.count > 25_165_824 { buffer.removeAll(); continue }
                    while let index = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                        DispatchQueue.main.async { guard self?.generation == token else { return }; self?.receive(object) }
                    }
                }
            }
        } catch { alert(error) }
    }
    func traceTest(_ value: String) { if testPasteboardName != nil { try? FileHandle.standardError.write(contentsOf: Data(("TEST " + value + "\n").utf8)) } }
    func send(_ object: [String: Any]) {
        traceTest("send " + (object["op"] as? String ?? "unknown"))
        guard let input = input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try input.write(contentsOf: data + Data([10])) } catch { status.stringValue = "Sync engine disconnected" }
    }
    func receive(_ object: [String: Any]) {
        traceTest("receive " + (object["type"] as? String ?? "unknown") + " " + (object["state"] as? String ?? ""))
        switch object["type"] as? String {
        case "clipboard":
            guard !config.paused, let event = object["event"] as? [String: Any], let text = event["text"] as? String else { return }
            pendingRemote = (event["mime"] as? String ?? "text/plain", text); applyRemote()
        case "status":
            latestConnection = object; renderConnection(); if let group = try? sharingGroup() { inviteDisplay.string = group.invitation }
        case "error": status.stringValue = object["message"] as? String ?? "Sync error"
        default: break
        }
    }
    static let maxPNG = 8 * 1024 * 1024
    static func png(_ data: Data) -> Bool {
        guard data.count <= maxPNG, data.count >= 24, Array(data.prefix(8)) == [137,80,78,71,13,10,26,10],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return w > 0 && h > 0 && w <= 16384 && h <= 16384 && Int64(w) * Int64(h) <= 40_000_000
    }
    func applyRemote() {
        guard let pending = pendingRemote else { return }
        let board = pasteboard
        if pending.mime == "image/png" {
            guard let data = Data(base64Encoded: pending.value), Self.png(data) else { pendingRemote = nil; status.stringValue = "Rejected invalid or oversized PNG"; return }
            board.clearContents()
            if board.setData(data, forType: .png) { lastChange = board.changeCount; pendingRemote = nil }
        } else if pending.mime == "text/plain" {
            board.clearContents()
            if board.setString(pending.value, forType: .string) { lastChange = board.changeCount; pendingRemote = nil }
        } else { pendingRemote = nil }
    }
    func pollClipboard() {
        guard !config.paused, !config.groups.isEmpty, child?.isRunning == true else { lastChange = pasteboard.changeCount; return }
        if pendingRemote != nil { applyRemote(); return }
        let board = pasteboard
        guard board.changeCount != lastChange else { return }; lastChange = board.changeCount
        traceTest("local revision")
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !blocked.contains(where: { board.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        // Prefer image data when applications publish both an image and a text description.
        if let png = board.data(forType: .png) {
            if Self.png(png) { send(["op": "copy_image", "data": png.base64EncodedString()]) }
            else { status.stringValue = "Image exceeds 8 MiB or 40 million pixels" }
            return
        }
        if let tiff = board.data(forType: .tiff), let source = CGImageSourceCreateWithData(tiff as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0, w <= 16384, h <= 16384, Int64(w) * Int64(h) <= 40_000_000,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]), Self.png(png) {
            send(["op": "copy_image", "data": png.base64EncodedString()]); return
        }
        guard let text = board.string(forType: .string), text.utf8.count <= 1_048_576,
              !text.contains("clipmesh://join#") else { return }
        send(["op": "copy", "text": text])
    }
    @objc func migrateStable() {
        do {
            let group = try sharingGroup()
            guard (group.seeds?.count ?? 0) >= 2 else { throw AppError.invalid("다른 기기가 한 대 이상 연결된 뒤 전환하세요. 새 기기는 연결용 QR로 참가할 수 있습니다.") }
            try add(group)
        } catch { alert(error) }
    }
    func sharingGroup() throws -> Group {
        guard var group = config.groups.first(where: { $0.id == config.active_group }) else { throw AppError.invalid("먼저 그룹을 선택하세요.") }
        guard group.transport == "p2p" else { return group }
        if latestConnection["group"] as? String == config.active_group, let ids = latestConnection["seed_ids"] as? [String], let own = latestConnection["self_id"] as? String, ids.contains(own) { group.seeds = Array(ids.prefix(16)); group.relay = "" }
        else { throw AppError.invalid("동기화를 켜고 연결 신원이 준비될 때까지 잠시 기다린 뒤 QR을 다시 여세요.") }
        return group
    }
    @objc func showQR() {
        let group: Group
        do { group = try sharingGroup() } catch { alert(error); return }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(group.invitation.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)), let cg = CIContext().createCGImage(output, from: output.extent) else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let panel = NSAlert(); panel.messageText = "Scan to join \(group.name)"; panel.informativeText = "This QR contains the group secret. Show it only to a device you trust."
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: cg.width + 40, height: cg.height + 40)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor.white.cgColor
        view.image = image; view.imageScaling = .scaleNone
        panel.accessoryView = view; panel.runModal()
    }
    @objc func joinQR() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.png, .jpeg, .tiff]; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 20 * 1024 * 1024, let image = CIImage(data: data), image.extent.width * image.extent.height <= 40_000_000,
                  let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
                  let code = detector.features(in: image).compactMap({ ($0 as? CIQRCodeFeature)?.messageString }).first(where: { $0.hasPrefix("clipmesh://join#") }) else { throw AppError.invalid("No ClipMesh QR found in this image") }
            try add(Group.parse(code))
        } catch { alert(error) }
    }
    func dashboardSelfTest() throws {
        let saved = config; let connection = latestConnection
        defer { config = saved; latestConnection = connection; refreshGroups() }
        func check(_ condition: Bool) throws { if !condition { throw AppError.invalid("Dashboard state check failed") } }
        try check(advancedStack.isHidden)
        let seeded = Group(name: "서버 없는 그룹", relay: "", key: Data(repeating: 8, count: 32).base64EncodedString(), transport: "p2p", seeds: [String(repeating: "a", count: 64)])
        let restored = try Group.parse(seeded.invitation)
        try check(restored.relay.isEmpty && restored.seeds == seeded.seeds)
        do { _ = try Group.parse(Group(name: "invalid legacy", relay: "", key: seeded.key).invitation); throw AppError.invalid("Accepted invalid legacy relay") } catch AppError.invalid(let message) { try check(message != "Accepted invalid legacy relay") }
        let group = Group(name: "Dashboard test", relay: "ws://127.0.0.1:47391", key: Data(repeating: 7, count: 32).base64EncodedString(), transport: "p2p")
        config.groups = [group]; config.active_group = group.id; config.paused = false
        latestConnection = ["connected": true, "transport": "p2p-direct", "connected_peer_count": 3, "known_peer_count": 99]; refreshGroups()
        try check(pauseToggle.state == .on && status.stringValue.contains("켜짐") && peersLabel.stringValue.contains("다른 기기 3대"))
        config.paused = true; refreshGroups(); try check(pauseToggle.state == .off && status.stringValue == "동기화 꺼짐")
        config.paused = false; latestConnection = ["connected": true]; renderConnection(); try check(peersLabel.stringValue.contains("확인할 수 없습니다"))
        latestConnection = ["connected": true, "peers": 0]; renderConnection(); try check(status.stringValue.contains("찾는 중"))
    }
    func imageSelfTest() throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw AppError.invalid(message) } }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<3 { for x in 0..<4 { rep.setColor(x % 2 == 0 ? .red : .blue, atX: x, y: y) } }
        let data = rep.representation(using: .png, properties: [:])!
        try check(Self.png(data), "valid PNG rejected")
        try check(!Self.png(Data("not an image".utf8)), "invalid PNG accepted")
        let board = NSPasteboard(name: NSPasteboard.Name("dev.clipmesh.test." + UUID().uuidString)); defer { board.releaseGlobally() }
        board.clearContents(); try check(board.setData(data, forType: .png), "PNG pasteboard write failed")
        try check(board.data(forType: .png) == data, "PNG pasteboard bytes changed")
        let tiff = rep.tiffRepresentation!; let decoded = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try check(Self.png(decoded), "TIFF to PNG conversion failed")
        let group = Group(name: "QR test", relay: "ws://127.0.0.1:47391", key: Data(repeating: 7, count: 32).base64EncodedString(), transport: "p2p")
        let filter = CIFilter(name: "CIQRCodeGenerator")!; filter.setValue(Data(group.invitation.utf8), forKey: "inputMessage")
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let white = CIImage(color: CIColor.white).cropped(to: output.extent.insetBy(dx: -24, dy: -24)); let qr = output.composited(over: white)
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        let raster = CIContext().createCGImage(qr, from: qr.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())!
        let code = detector.features(in: CIImage(cgImage: raster)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        try check(code == group.invitation, "QR round-trip failed")
        try? fm.removeItem(at: configURL.deletingLastPathComponent())
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); stopCore(); relayChild?.terminate() }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
