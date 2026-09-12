#!/usr/bin/env bash
# Starts the API on this Mac and exposes it at https://hs.poyraz.us through a
# Cloudflare Tunnel. One-time setup is in the README. Ctrl-C stops both.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { cp .env.example .env; echo "Created .env — set SECRET_KEY."; }
set -a; source .env; set +a
uvicorn app.main:app --host 127.0.0.1 --port 8000 &
API=$!
trap 'kill $API 2>/dev/null' EXIT
cloudflared tunnel run --url http://localhost:8000 heisoj
