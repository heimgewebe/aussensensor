#!/usr/bin/env bash
set -euo pipefail

# Sende nur vollständige JSON-Objekte (eine Zeile = ein Event).
# Multi-Line-JSON würde in Fragmente zerfallen – das verhindern wir mit jq -c.

FEED_FILE="${FEED_FILE:-export/feed.jsonl}"
ENDPOINT="${ENDPOINT:-${LEITSTAND_INGEST_URL:-http://127.0.0.1:8788/ingest/aussen}}"
AGENT="${AGENT:-aussensensor}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 127; }; }
need jq
need curl
need tail

[[ -s "$FEED_FILE" ]] || { echo "no feed"; exit 0; }

echo "push_leitstand: streaming $FEED_FILE -> $ENDPOINT (agent=$AGENT)" >&2

# Compact-on-the-fly: jede gelesene Zeile muss parsebar sein; leere/Whitespace-Zeilen überspringen.
tail -n +1 -F "$FEED_FILE" |
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line// }" ]] || continue
  compact="$(printf '%s\n' "$line" | jq -c . 2>/dev/null)" || {
    echo "skip invalid JSON line" >&2
    continue
  }
  curl -fsS -X POST \
    -H "content-type: application/json" \
    -H "x-agent: ${AGENT}" \
    --data-binary "$compact" \
    "$ENDPOINT" || echo "warn: POST failed" >&2
done
