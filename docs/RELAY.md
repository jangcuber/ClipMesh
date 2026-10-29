# Optional legacy WebSocket relay

ClipMesh 0.3.0 P2P groups normally use saved public endpoint IDs, iroh address lookup and encrypted relay fallback. They do not need a Mac-hosted WebSocket server or a temporary tunnel. This page describes the optional older WebSocket mode, which is still supported for explicitly configured groups.

For LAN use, enable the desktop advanced setting to host a relay on TCP47391. Every group member needs an address reachable from that member; `127.0.0.1` is only usable on the same machine.

For Internet deployment:

```sh
cargo build --release --locked -p clipmesh
./target/release/clipmesh relay --listen 127.0.0.1:47391
```

Alternatively:

```sh
docker compose -f scripts/compose.yaml up -d --build
```

Expose only the relay through an HTTPS WebSocket reverse proxy using your own hostname. For example, with Caddy:

```caddy
sync.example.com {
    reverse_proxy 127.0.0.1:47391
}
```

Use `wss://sync.example.com` for that group. The clients connect outbound; do not expose SSH or unrelated local services. A WebSocket group depends on its configured server being reachable. Ephemeral test tunnels can change address and are not the default 0.3 connection design.

The relay cannot decrypt group envelopes. It does see group route identifiers, addresses, timing and sizes. It bounds peers/groups/frame sizes and retains bounded encrypted frames only while a group is live. Possession of a group ID alone does not authenticate membership to the server, so public deployments should apply connection/rate limits at the proxy. Clients authenticate and reject forged application events.
