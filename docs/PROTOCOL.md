# ClipMesh protocol v1

Implemented independently for Rust, Swift/CryptoKit and Kotlin/JCA. Desktop shells use the Rust process over newline-delimited JSON; mobile clients use the same encrypted wire protocol directly, so they need no separately installed daemon or language runtime. v0.2 clients support text and bounded PNG images; text events keep the v1 wire format. No vendor accounts, Apple IDs or Microsoft accounts.

## Pairing

A group consists of a human name, relay base URL and uniformly random 32-byte key. Invitation:

```
clipmesh://join#BASE64URL_NO_PAD(UTF8(JSON({"v":1,"name":"My devices","relay":"wss://sync.example.com","key":"STANDARD_BASE64_32_BYTES"})))
```

Group names must be nonblank and at most 200 UTF-8 bytes; invitation links are bounded at 8192 bytes. Group ID is lowercase hexadecimal SHA-256 of the decoded key. Relay URL must use a root path, no credentials/query/fragment, `ws` (LAN) or `wss` (external network). Every device connects outbound to `/v1/ws/{groupId}`. The invite is a long-lived bearer secret. Anyone receiving it can decrypt, read, and inject group messages. There is no central account, per-device cryptographic membership, expiry, revocation list or forward secrecy in v1. Remove a device by creating a new group and inviting only remaining devices. Invitations are filtered from automatic clipboard transmission.

## Envelope

```json
{"v":1,"group":"64 lowercase hexadecimal characters","nonce":"standard-base64","ciphertext":"standard-base64"}
```

AES-256-GCM with fresh random 96-bit nonce on every encryption. `ciphertext` is encrypted UTF-8 JSON followed by the 16-byte GCM authentication tag. AAD is exactly UTF-8 `clipmesh:v1:{groupId}`. A wrong group, nonce, tag, unsupported MIME or malformed event is rejected. Golden cross-language vector: `crates/clipmesh/tests/v1-vector.json`.

Decrypted clipboard event:

```json
{"v":1,"id":"lowercase UUID","device":"lowercase UUID","clock":1,"created_ms":1790000000000,"mime":"text/plain","text":"Hello 안녕하세요"}
```

Text bound: 1 MiB **UTF-8 bytes**, including empty text. JSON escaping can expand the wire frame, so transport bounds are larger. Logical clocks must remain below `2^53-1`; event wall-clock timestamps are informational and never choose a winner. UUIDs emitted by clients are lowercase.

## Conflict and loop handling

Each group has its own logical clock and winning register. Valid events are ordered by `(clock, device, id)` ascending; the greatest tuple wins. Device and event UUID comparison is ordinal ASCII. On receipt, advance Lamport time using the received clock; duplicates do not need another clipboard write. Local copies generate fresh UUIDs and advance the clock. This converges under simultaneous copy independent of delivery order. The timestamp on a device with a skewed clock cannot dominate the group.

Native hosts suppress the notification caused by writing a remote value, and the core suppresses repeated event IDs. On startup clients do not publish the pre-existing local clipboard. They can receive the group's latest retained event, so joining can change the local clipboard. On reconnect a client republishes its group winner; clients converge through the same total order. Disconnected copies collapse into the latest register rather than growing an unbounded queue. No promise of delivering every intermediate copy while a device is offline.

The relay keeps up to 16 recent opaque frames / 16 MiB per live group; when all peers leave, its group state is dropped. It never decrypts clipboard contents or writes a clipboard database. Clients may persist encrypted group state. Metadata (group ID, connection addresses, packet sizes/timing) is visible to the relay. A shared group key authenticates group membership, but does not prove a specific claimed device identity.

## Host bridge

`clipmesh run --config /path/config.json` reads one JSON command per stdin line, writes one JSON response per stdout line. Diagnostics go to stderr and never intentionally include clipboard text. Do not place secrets in logs.

Inputs: `{"op":"copy","text":"…"}`, `{"op":"copy_image","data":"STANDARD_BASE64_PNG"}`, `{"op":"pause","paused":true}`, `{"op":"status"}`, `{"op":"history"}`, `{"op":"clear_history"}`, `{"op":"quit"}`.

Outputs: `{"type":"clipboard","event":{...}}`, `{"type":"copied","id":"…","clock":1}`, `{"type":"status","state":"connected","connected":true,"paused":false}`, `{"type":"history","events":[...]}`, `{"type":"error","message":"…"}`. History is plaintext only while explicitly returned to the local host process; stored core history is encrypted with the group key.

```json
{"v":1,"device":"a locally generated UUID","name":"My Mac","groups":[{"name":"My devices","relay":"ws://192.168.1.10:47391","key":"standard-base64"}],"active_group":"group ID","paused":false}
```

Config is a local secret file: owner-only Unix permissions / Windows profile ACL. The key must be available to the client; disk protection still depends on OS user isolation and disk encryption. No cloud backup or telemetry is added by ClipMesh.

## PNG image extension (v0.2)

Images use the same authenticated event/register ordering: `mime` is `image/png`, and `text` contains standard Base64 PNG bytes. The decoded PNG is at most 8 MiB, dimensions are positive and each at most 16384, with at most 40,000,000 pixels. Before native decoding all clients verify the PNG signature and first IHDR chunk. Native hosts decode and normalize their local bitmap clipboard to PNG, then expose received bytes as native image clipboard data. This is an image clipboard, not an image path or downloadable URL. Old clients reject image events; upgrade every group device before using images. A text event still has `mime: "text/plain"` and a 1 MiB UTF-8 limit. Maximum wire frame is 24 MiB to accommodate base64 plus envelope expansion. The encrypted history remains bounded; the current winner is retained separately even when a large image exceeds the 4 MiB history budget.

## Optional QUIC mesh (v0.2)

Groups and invitation JSON can include `"transport":"p2p"`. Absent means the original WebSocket path, preserving existing installed clients and golden vectors. New native clients can opt existing groups in with their P2P setting. All devices in a mesh group must be upgraded and opted in; legacy peers are not part of mesh peer discovery. QR codes carry the complete invite locally, including this capability, with no secret upload to a QR service. There is no six-digit pairing secret or short-code lookup server.

The Rust transport uses [iroh 1.4.1](https://docs.rs/iroh/1.4.1/iroh/) over ALPN `clipmesh/mesh/1`. QUIC/TLS authenticates endpoint identities; a group-encrypted hello proves group membership and exchanges a per-process boot UUID. Deterministic connection side selection removes duplicate simultaneous dials, while a changed authenticated boot nonce permits reconnecting the same endpoint identity before an old connection times out. Every application frame is still an authenticated ClipMesh envelope, validated before forwarding and on receipt.

A separate WS room exchanges encrypted peer endpoint addresses every three seconds. Its key is `SHA256(UTF8("clipmesh:discovery:1:") || decodedGroupKey)`; its room ID is SHA256 of that derived key. Its encrypted payload is `{"kind":"clipmesh-peer-v1","addr":IROH_ENDPOINT_ADDR_JSON}`. These advertisements never enter the clipboard data room, so legacy clients do not receive non-clipboard metadata. First discovery needs the configured WebSocket rendezvous online. Known endpoint addresses and the local endpoint secret/UDP port are saved in an owner-only `.GROUPID.mesh` file next to the config, capped at 32 peers and 128 KiB when loading. Once peers know each other, they connect and reconnect without that WS server, including after a peer process restart. If the persisted UDP port is occupied, the endpoint binds another free port; address lookup can discover its new network address, but recovery then depends on the lookup/relay services being reachable.

Connected mesh peers receive payloads over QUIC. iroh attempts NAT traversal and upgrades to direct paths; if direct paths are blocked, it uses encrypted iroh relay connections. While any known peer is not connected (or no peer exists), data also goes through the original opaque WebSocket fallback. A stale offline known peer can therefore cause redundant encrypted WS delivery; event IDs/order suppress duplicate clipboard writes. Incoming QUIC handshakes have five-second limits with at most eight concurrent handshakes. Latest outgoing values replace pending values per peer, preventing a slow image transfer from silently losing the final copy. Transport replay preserves the greatest event ordering tuple rather than the last packet received.

The mesh uses the official iroh N0 public discovery/relay defaults (`iroh.link` and Number 0 relay infrastructure). Those services can see endpoint IDs, network addresses, and traffic metadata. They do not receive the group key or plaintext clipboard. Public relay uptime and NAT traversal are outside ClipMesh's control; P2P is preferred, not guaranteed on every network. The temporary Cloudflare WS tunnel is still a rendezvous/fallback in the current deployment. This implementation does not deploy a permanent private discovery/relay server or guarantee joining a new device when all rendezvous services are offline.

`clipmesh transport --config FILE` is the native-mobile network subprocess interface. stdin accepts `{"op":"send","frame":"SERIALIZED_ENVELOPE_JSON"}` and `{"op":"quit"}`. stdout emits `{"type":"frame","frame":"SERIALIZED_ENVELOPE_JSON"}` and `{"type":"status","state":"connected","connected":true,"transport":"p2p-direct|iroh-relay|websocket|reconnecting","peers":1}`. It accesses no OS clipboard. Native hosts keep their existing cryptography and register. Restart it when config/group/paused state changes.

## Remaining extensions

Files, HTML/rich text, authenticated membership revocation and a history UI remain separate work. PNG image support does not implement arbitrary file transfer, file promises, or streaming video.

## Device presence status (v0.2.3)

The existing `peers` integer remains the number of **other live, group-authenticated QUIC peers**, excluding this device. New status fields are `connected_peer_count` (same value), `known_peer_count` (cached/discovered identities, including offline devices), `direct_peer_count`, `relay_peer_count`, `self_id` (endpoint ID), `self_name`, and `peer_details`. Each live detail has `{id,name,device,platform,route}`; `route` is `direct`, `relay`, or `connecting`. Old advertisements have empty names/platform/device metadata; their endpoint ID still identifies a live connection. A connected WebSocket alone does not prove another device is online, and the cached count must not be shown as an online-device count. Mixed groups can contain direct and relayed routes at the same time; use the per-peer route/count fields to describe that accurately.

Encrypted `clipmesh-peer-v1` advertisements may optionally contain `name`, `device` and `platform`. Names are bounded at 200 UTF-8 bytes with control characters rejected, device IDs are UUIDs or empty for legacy peers, and platforms are from a fixed allowlist. Metadata is group-authenticated, not a separately verified human/device identity; every holder of the shared group key can claim a name. Peer metadata persists in the owner-only mesh cache for display, without turning cached entries into live peers.

`clipmesh inspect --config FILE --seconds 12` observes only the encrypted discovery WebSocket. It never binds an iroh endpoint, sends an advertisement, subscribes to clipboard events, or changes config/cache/OS clipboard. It ignores the first three seconds of retained replay, then reports freshly advertising endpoints with 16-character ID prefixes and a self marker when the existing endpoint cache is available. This proves fresh group-authenticated advertisements during the observation window, **not** that every pair has established QUIC or that clipboard paste succeeded. Allowed observation time is 8–30 seconds. It can fail when the configured temporary WS rendezvous hostname expires even while previously registered devices continue using cached P2P connections.

## Seeded relay-free groups (v0.3.0)

Version 0.3 extends the optional QUIC mesh so a Mac-hosted WebSocket server or temporary Cloudflare hostname is no longer required for a group to start, pair, reconnect, or exchange clipboard events. This supersedes the v0.2 first-discovery WebSocket requirement above **for upgraded seeded groups**. Legacy groups with a nonempty relay retain their original optional WS rendezvous/fallback behavior.

A group/invite can carry `seeds`, a list of at most 32 lowercase 64-character endpoint public IDs. `relay: ""` is accepted only with `transport: "p2p"`; no WebSocket tasks are started in that mode. Seeds are public routing identities, never endpoint private keys. A newly created relay-free group must start sync once to create its persistent endpoint identity before exporting a useful invitation. `seed_ids` in core status contains the local endpoint ID first and known peers next, bounded at 32. QR exports use at most 16 IDs to stay within practical QR capacity. `group export --config FILE --without-relay` reads the existing identity/peer cache, enriches the invite with these public IDs, and removes the optional relay **only from the exported invite**. It does not alter the config or bind another endpoint. Rejoining the same group ID replaces its routing settings while preserving the existing device identity and unrelated groups.

Iroh N0 signed Pkarr/DNS/HTTPS address lookup automatically publishes and resolves the current routes for persistent endpoint IDs. The endpoint secret is kept in the owner-only mesh cache and reused across app/device restarts. UDP port reuse is an optimization; a new free port and changed network addresses are resolved through the signed address lookup infrastructure. A recipient only needs one reachable known seed; it does not need a stable Mac IP or a temporary WS hostname. If every invited seed is offline and the new device has never learned another online member, first joining waits until a known member returns. A seed invitation is not a centralized always-online group mailbox.

The group-encrypted hello now optionally carries the sender's endpoint address and bounded name/platform metadata. The claimed address ID must equal the QUIC/TLS-authenticated remote endpoint. An unknown endpoint is admitted only after its hello decrypts/authenticates with the group key and the bounded peer limit permits it. The shared-key model means any group-key holder is a group member; this is not per-device revocation or an independent trust assertion about a human name.

Connected members periodically exchange an encrypted control payload `{"kind":"clipmesh-peers-v1","entries":[{"addr":IROH_ENDPOINT_ADDR,"name":"...","device":"...","platform":"..."}]}`. It has at most 32 entries, a 64 KiB decode bound, at most 16 routes and 4096 serialized bytes per address, and the same metadata limits as advertisements. This peer address book introduces members so peers converge to a mesh and retain enough independent seeds to continue after the original creator goes offline. Third-party cache entries cannot overwrite a newer address learned from the endpoint owner's authenticated hello. Control frames never enter the native clipboard event stream and cannot become clipboard text or history entries. Their queue is separate from the latest clipboard-value queue, so periodic presence traffic does not replace a pending final copy.

This removes dependence on the user's Mac server and changing temporary-tunnel address. It does **not** remove all external infrastructure: N0 public discovery and relay services carry endpoint/routing metadata and encrypted QUIC fallback traffic. Public service uptime/rate limits have no ClipMesh SLA; production operators can choose managed or self-hosted iroh infrastructure separately. No cloud account, domain registration, paid relay subscription, or permanent server was provisioned by this change.

The explicit network integration test `serverless_three_peer_seed_join_mac_off_and_all_peer_restart_new_ports` uses the actual public N0 services with no ClipMesh WS listener. It checks ID-only first join, encrypted address-book convergence, creator shutdown, remaining-peer text/PNG exchange, and restart of every remaining peer after wiping old route hints and selecting new ports while retaining endpoint IDs. It is opt-in for offline CI stability and must be run explicitly when claiming this deployment layer. Native Windows/Android/iOS startup, clipboard APIs, background behavior and physical restart tests remain separate evidence layers.
