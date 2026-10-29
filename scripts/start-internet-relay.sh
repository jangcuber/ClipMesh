#!/bin/bash
# Start only the ClipMesh endpoint. No group keys are passed to cloudflared.
set -euo pipefail
command -v cloudflared >/dev/null || { echo 'Install cloudflared from its official distribution first.' >&2; exit 1; }
echo 'Keep ClipMesh running with Host a LAN relay enabled on TCP47391.' >&2
echo 'This creates a NEW temporary hostname. Update the group relay and invitations after restart.' >&2
exec cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:47391
