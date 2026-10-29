import Foundation

@main struct ProtocolCheck {
    static func main() throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../../crates/clipmesh/tests/v1-vector.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let group = try Group.parse(fixture["uri"] as! String)
        precondition(group.id == fixture["groupId"] as! String)
        let envelope = try JSONSerialization.data(withJSONObject: fixture["envelope"]!)
        let event = try Wire.open(envelope, group: group)
        let expected = try JSONSerialization.data(withJSONObject: fixture["event"]!)
        let decoded = try JSONDecoder().decode(ClipEvent.self, from: expected)
        precondition(event.text == decoded.text && event.order == decoded.order)
        let sealed = try Wire.seal(event, group: group)
        let roundTrip = try Wire.open(sealed, group: group)
        precondition(roundTrip.text == event.text)
        var bad = try JSONDecoder().decode(Envelope.self, from: envelope)
        var cipher = Data(base64Encoded: bad.ciphertext)!
        cipher[0] ^= 1; bad.ciphertext = cipher.base64EncodedString()
        do { _ = try Wire.open(JSONEncoder().encode(bad), group: group); fatalError("Tamper was accepted") } catch {}
        do { _ = try Group.parse("clipmesh://join#bad"); fatalError("Invalid code was accepted") } catch {}
        precondition(EventOrder(clock: 1, device: "a", id: "b") < EventOrder(clock: 1, device: "b", id: "a"))
        var boundaryGroup = group
        boundaryGroup.name = String(repeating: "한", count: 66) + "ab"
        precondition(boundaryGroup.name.utf8.count == 200)
        try boundaryGroup.validate()
        let boundaryPairing = try Group.parse(boundaryGroup.pairing)
        precondition(boundaryPairing.name == boundaryGroup.name)
        boundaryGroup.name += "c"
        do { try boundaryGroup.validate(); fatalError("201-byte group name was accepted") } catch {}
        boundaryGroup.name = " \n\t "
        do { try boundaryGroup.validate(); fatalError("Blank group name was accepted") } catch {}
        var boundaryClock = event
        boundaryClock.clock = maxClock - 1
        try boundaryClock.validate()
        boundaryClock.clock = maxClock
        do { try boundaryClock.validate(); fatalError("Maximum clock was accepted") } catch {}
        boundaryClock.clock = 0
        do { try boundaryClock.validate(); fatalError("Zero clock was accepted") } catch {}
        // A process restart loses all plaintext state. The ciphertext winner must
        // recover the same event while rejecting an older competing event.
        var state = GroupState()
        let firstWins = try state.observe(event, group: group)
        precondition(firstWins)
        let disk = try JSONEncoder().encode(EngineState(groups: [group.id: state]))
        precondition(!String(decoding: disk, as: UTF8.self).contains(event.text))
        let restored = try JSONDecoder().decode(EngineState.self, from: disk)
        var restoredState = restored.groups[group.id]!
        let recovered = try restoredState.winningEvent(group: group)
        precondition(recovered?.text == event.text && recovered?.order == event.order)
        var old = event; old.clock = event.clock - 1; old.text = "old winner"
        let oldWins = try restoredState.observe(old, group: group)
        precondition(!oldWins)
        let stillWinner = try restoredState.winningEvent(group: group)
        precondition(stillWinner?.order == event.order)
        var legacy = GroupState(clock: event.clock, latest: event.order, winner: nil)
        let duplicateWins = try legacy.observe(event, group: group)
        precondition(!duplicateWins)
        let upgraded = try legacy.winningEvent(group: group)
        precondition(upgraded?.text == event.text)
        var corrupt = restoredState
        corrupt.latest = old.order
        do { _ = try corrupt.winningEvent(group: group); fatalError("Mismatched stored metadata was accepted") } catch {}
        let imageVectorURL = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("v1-image-vector.json")
        let imageFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: imageVectorURL)) as! [String: Any]
        let imageGroup = try Group.parse(imageFixture["uri"] as! String)
        let imageVector = try Wire.open(JSONSerialization.data(withJSONObject: imageFixture["envelope"]!), group: imageGroup)
        let expectedImageVector = try JSONDecoder().decode(ClipEvent.self, from: JSONSerialization.data(withJSONObject: imageFixture["event"]!))
        precondition(imageVector.mime == "image/png" && imageVector.text == expectedImageVector.text && imageVector.order == expectedImageVector.order)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg==")!
        try validatePNG(png)
        var image = event; image.mime = "image/png"; image.text = png.base64EncodedString()
        let encryptedImage = try Wire.seal(image, group: group)
        let recoveredImage = try Wire.open(encryptedImage, group: group)
        precondition(recoveredImage.mime == "image/png" && Data(base64Encoded: recoveredImage.text) == png)
        var dimensions = png; dimensions[16] = 0x7f
        do { try validatePNG(dimensions); fatalError("Oversized dimensions accepted") } catch {}
        var pixels = png; pixels[18] = 0x20; pixels[22] = 0x20
        do { try validatePNG(pixels); fatalError("Pixel bomb accepted") } catch {}
        do { try validatePNG(Data(repeating: 0, count: 40)); fatalError("Non-PNG accepted") } catch {}
        image.text = String(repeating: "A", count: ((maxImageBytes + 2) / 3) * 4 + 4)
        do { try image.validate(); fatalError("Oversized encoded image accepted") } catch {}
        var p2pGroup = group; p2pGroup.transport = "p2p"
        let restoredP2P = try Group.parse(p2pGroup.pairing)
        precondition(restoredP2P.transport == "p2p" && restoredP2P.id == group.id)
        // A relay-free invitation can still rendezvous after the creator's Mac is offline.
        var automatic = group; automatic.relay = ""; automatic.transport = "p2p"; automatic.seeds = [String(repeating: "a", count: 64)]
        try automatic.validate(); precondition(automatic.endpoint == nil)
        let automaticInvite = try Group.parse(automatic.pairing)
        precondition(automaticInvite.seeds == automatic.seeds && automaticInvite.relay.isEmpty)
        let oldConfigJSON = try JSONSerialization.data(withJSONObject: ["name": group.name, "relay": group.relay, "key": group.key])
        let compatible = try JSONDecoder().decode(Group.self, from: oldConfigJSON)
        precondition(compatible.v == 1 && compatible.seeds.isEmpty)
        automatic.transport = nil
        do { try automatic.validate(); fatalError("Relay-free legacy group accepted") } catch {}
        automatic.transport = "p2p"; automatic.seeds = [String(repeating: "A", count: 64)]
        do { try automatic.validate(); fatalError("Noncanonical seed ID accepted") } catch {}
        automatic.seeds = Array(repeating: String(repeating: "a", count: 64), count: 33)
        do { try automatic.validate(); fatalError("Unbounded seed list accepted") } catch {}
        let shareTime = Date(timeIntervalSince1970: 1_800_000_000)
        let ownSeed = String(repeating: "b", count: 64)
        let manySeeds = (0..<32).map { String(format: "%064x", $0 + 1) }
        let sharingStatus: [String: Any] = ["group_id": p2pGroup.id, "self_id": ownSeed, "seed_ids": manySeeds, "updated_ms": shareTime.timeIntervalSince1970 * 1000]
        let exported = p2pGroup.shareable(status: sharingStatus, now: shareTime)!
        precondition(exported.relay.isEmpty && exported.seeds.first == ownSeed && exported.seeds.count == 16)
        precondition(!p2pGroup.relay.isEmpty) // Sharing cannot mutate the active legacy config.
        precondition(p2pGroup.shareable(status: sharingStatus, now: shareTime.addingTimeInterval(11)) == nil)
        var wrongGroup = sharingStatus; wrongGroup["group_id"] = "wrong"
        precondition(p2pGroup.shareable(status: wrongGroup, now: shareTime) == nil)
        precondition(p2pGroup.shareable(status: nil, now: shareTime) == nil)
        print("PASS: cross-language AES-GCM fixture, pairing/group ID, round trip, tamper rejection, invalid pairing, UTF8 name/clock boundaries, ordering, encrypted winner recovery, stale replay rejection, legacy upgrade, independent Node AES-GCM image fixture, PNG encryption/limits, P2P invite preservation, relay-free seed invitations and legacy config decoding, own-ID-first relay-free export with stale/group guards")
    }
}
