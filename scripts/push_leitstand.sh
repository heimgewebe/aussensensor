#!/usr/bin/env bash
set -euo pipefail
URL="${LEITSTAND_INGEST_URL:-http://127.0.0.1:8788/ingest/aussen}"
FILE="export/feed.jsonl"
[ -s "$FILE" ] || { echo "no feed"; exit 0; }
N="${1:-1}"
tail -n "$N" "$FILE" | while IFS= read -r line; do
  if [ -n "${LEITSTAND_TOKEN:-}" ]; then
    curl -fsS -H 'content-type: application/json' -H "x-auth: ${LEITSTAND_TOKEN}" --data-binary "$line" "$URL" >/dev/null
  else
    curl -fsS -H 'content-type: application/json' --data-binary "$line" "$URL" >/dev/null
  fi
done
echo "pushed last $N event(s) to $URL"
