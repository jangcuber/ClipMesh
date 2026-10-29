import Foundation
import CryptoKit

let configurationURL = URL(fileURLWithPath: "/var/mobile/Library/Preferences/dev.clipmesh.ios.json")
let statusURL = URL(fileURLWithPath: "/var/mobile/Library/Preferences/dev.clipmesh.ios.status.json")
let stateURL = URL(fileURLWithPath: "/var/mobile/Library/Preferences/dev.clipmesh.ios.state.json")
let maxClock: UInt64 = 9_007_199_254_740_991
let maxTextBytes = 1_048_576
let maxImageBytes = 8 * 1024 * 1024
let maxFrameBytes = 24 * 1024 * 1024

enum ClipError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
struct Group: Codable, Equatable {
    var v = 1
    var name: String
    var relay: String
    var key: String
    var transport: String? = nil
    var seeds: [String] = []
    enum CodingKeys: String, CodingKey { case v, name, relay, key, transport, seeds }
    init(v: Int = 1, name: String, relay: String, key: String, transport: String? = nil, seeds: [String] = []) {
        self.v = v; self.name = name; self.relay = relay; self.key = key; self.transport = transport; self.seeds = seeds
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decodeIfPresent(Int.self, forKey: .v) ?? 1
        name = try values.decode(String.self, forKey: .name)
        relay = try values.decodeIfPresent(String.self, forKey: .relay) ?? ""
        key = try values.decode(String.self, forKey: .key)
        transport = try values.decodeIfPresent(String.self, forKey: .transport)
        seeds = try values.decodeIfPresent([String].self, forKey: .seeds) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(v, forKey: .v); try values.encode(name, forKey: .name)
        try values.encode(relay, forKey: .relay); try values.encode(key, forKey: .key)
        try values.encodeIfPresent(transport, forKey: .transport)
        if !seeds.isEmpty { try values.encode(seeds, forKey: .seeds) }
    }
    var keyData: Data { Data(base64Encoded: key) ?? Data() }
    var id: String { SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined() }
    static func validSeed(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func validate() throws {
        guard transport == nil || transport == "p2p", v == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200, keyData.count == 32,
              seeds.count <= 32, seeds.allSatisfy(Group.validSeed) else { throw ClipError.invalid("Invalid group, peer seeds, or 32-byte key") }
        if relay.isEmpty {
            guard transport == "p2p" else { throw ClipError.invalid("A legacy relay group needs a relay URL") }
            return
        }
        guard let u = URLComponents(string: relay), ["ws", "wss"].contains(u.scheme?.lowercased() ?? ""),
              u.host != nil, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { throw ClipError.invalid("Invalid relay URL") }
    }
    var endpoint: URL? {
        guard !relay.isEmpty else { return nil }
        return URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/ws/" + id)
    }
    static func parse(_ value: String) throws -> Group {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("clipmesh://join#"), trimmed.utf8.count <= 8192 else { throw ClipError.invalid("Paste a clipmesh://join# pairing code") }
        var encoded = String(trimmed.dropFirst("clipmesh://join#".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw ClipError.invalid("Invalid pairing encoding") }
        let group = try JSONDecoder().decode(Group.self, from: data)
        try group.validate()
        return group
    }
    /// Build a relay-independent invitation only after this group's persistent local ID is ready.
    func shareable(status: [String: Any]?, now: Date = Date()) -> Group? {
        guard transport == "p2p" else { return self }
        guard let value = status, value["group_id"] as? String == id,
              let updated = value["updated_ms"] as? Double,
              now.timeIntervalSince1970 * 1000 - updated < 10_000,
              let own = value["self_id"] as? String, Group.validSeed(own) else { return nil }
        var identifiers: [String] = []
        for candidate in [own] + (value["seed_ids"] as? [String] ?? []) + seeds where Group.validSeed(candidate) && !identifiers.contains(candidate) {
            identifiers.append(candidate); if identifiers.count == 16 { break }
        }
        var invitation = self; invitation.seeds = identifiers; invitation.relay = ""
        return invitation
    }
    var pairing: String {
        let data = try! JSONEncoder().encode(self)
        return "clipmesh://join#" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
struct Configuration: Codable {
    var v = 1
    var device = UUID().uuidString.lowercased()
    var name = "iPhone"
    var groups: [Group] = []
    var active_group = ""
    var paused = true
    var active: Group? { groups.first { $0.id == active_group } }
    static func load() -> Configuration {
        guard let data = try? Data(contentsOf: configurationURL), let value = try? JSONDecoder().decode(Configuration.self, from: data), value.v == 1, UUID(uuidString: value.device) != nil else { return Configuration() }
        return value
    }
    func save() throws { try secureWrite(JSONEncoder().encode(self), to: configurationURL) }
}
func secureWrite(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
struct ClipEvent: Codable {
    var v = 1
    var id: String
    var device: String
    var clock: UInt64
    var created_ms: UInt64
    var mime: String
    var text: String
    var order: EventOrder { EventOrder(clock: clock, device: device, id: id) }
    func validate() throws {
        guard v == 1, UUID(uuidString: id) != nil, UUID(uuidString: device) != nil,
              device == device.lowercased(), id == id.lowercased(),
              clock > 0, clock < maxClock else { throw ClipError.invalid("Unsupported or oversized clipboard event") }
        switch mime {
        case "text/plain":
            guard text.utf8.count <= maxTextBytes else { throw ClipError.invalid("Text exceeds 1 MiB") }
        case "image/png":
            guard text.utf8.count <= ((maxImageBytes + 2) / 3) * 4, let bytes = Data(base64Encoded: text) else { throw ClipError.invalid("Invalid image encoding") }
            try validatePNG(bytes)
        default: throw ClipError.invalid("Unsupported clipboard format")
        }
    }
}
struct EventOrder: Codable, Comparable {
    var clock: UInt64
    var device: String
    var id: String
    static func < (a: Self, b: Self) -> Bool {
        if a.clock != b.clock { return a.clock < b.clock }
        if a.device != b.device { return a.device < b.device }
        return a.id < b.id
    }
}
/// Metadata is plaintext; the only persisted clipboard payload is an authenticated
/// encrypted envelope. One winner per group is enough to recover convergence.
struct GroupState: Codable {
    var clock: UInt64 = 0
    var latest: EventOrder?
    var winner: Envelope?

    mutating func observe(_ event: ClipEvent, group: Group) throws -> Bool {
        try event.validate()
        let wins = latest == nil || event.order > latest!
        if wins || (event.order == latest && winner == nil) {
            // Also upgrades metadata-only state when its exact winner is replayed.
            winner = try JSONDecoder().decode(Envelope.self, from: Wire.seal(event, group: group))
            latest = event.order
        }
        clock = max(clock, event.clock)
        return wins
    }
    func winningEvent(group: Group) throws -> ClipEvent? {
        guard let winner else { return nil }
        let event = try Wire.open(JSONEncoder().encode(winner), group: group)
        guard event.order == latest, event.clock <= clock else { throw ClipError.invalid("Stored winner metadata mismatch") }
        return event
    }
}
struct EngineState: Codable { var groups: [String: GroupState] = [:] }

struct Envelope: Codable {
    var v = 1
    var group: String
    var nonce: String
    var ciphertext: String
}
enum Wire {
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func seal(_ event: ClipEvent, group: Group) throws -> Data {
        try event.validate()
        let sealed = try AES.GCM.seal(encode(event), using: SymmetricKey(data: group.keyData), authenticating: Data("clipmesh:v1:\(group.id)".utf8))
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return try encode(Envelope(group: group.id, nonce: nonce.base64EncodedString(), ciphertext: (sealed.ciphertext + sealed.tag).base64EncodedString()))
    }
    static func open(_ data: Data, group: Group) throws -> ClipEvent {
        guard data.count <= maxFrameBytes else { throw ClipError.invalid("Oversized envelope") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.v == 1, envelope.group == group.id,
              let nonce = Data(base64Encoded: envelope.nonce), nonce.count == 12,
              let cipher = Data(base64Encoded: envelope.ciphertext), cipher.count >= 16 else { throw ClipError.invalid("Invalid envelope") }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
        let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: group.keyData), authenticating: Data("clipmesh:v1:\(group.id)".utf8))
        let event = try JSONDecoder().decode(ClipEvent.self, from: plain)
        try event.validate()
        return event
    }
}

/// Inspect dimensions before any platform decoder allocates a bitmap.
func validatePNG(_ bytes: Data) throws {
    guard bytes.count >= 33, bytes.count <= maxImageBytes,
          Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
          Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82] else { throw ClipError.invalid("Invalid or oversized PNG") }
    func number(_ offset: Int) -> UInt64 { bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt64($1) } }
    let width = number(16), height = number(20)
    guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 40_000_000 else { throw ClipError.invalid("PNG dimensions exceed limits") }
}
