#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

API_BASE="${API_BASE:-https://openai-proxy.codex.hk}"
ENDPOINT="$API_BASE/v1/responses"

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "[ERROR] Please set OPENAI_API_KEY environment variable." >&2
  exit 1
fi

# Masked preview of the key for sanity without leaking secrets
MASKED_KEY=$(printf "%s" "$OPENAI_API_KEY" | sed -E 's/^(.{6}).+(.{6})$/\1...REDACTED...\2/')
echo "Using endpoint: $ENDPOINT"
echo "Authorization: Bearer $MASKED_KEY"

PAYLOAD_FILE="${1:-$ROOT_DIR/payload.responses.json}"
if [[ ! -f "$PAYLOAD_FILE" ]]; then
  echo "[ERROR] Payload file not found: $PAYLOAD_FILE" >&2
  exit 1
fi

echo "Sending request (streaming)..."
curl -N -sS -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  --data-binary @"$PAYLOAD_FILE"

