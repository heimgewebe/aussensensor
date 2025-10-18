#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-export/feed.jsonl}"
[[ -f "$FILE" ]] || { echo "missing $FILE"; exit 1; }
: "${HEIMLERN_INGEST_URL:?set HEIMLERN_INGEST_URL}"
curl -sS -X POST "$HEIMLERN_INGEST_URL" \
  -H "Content-Type: application/jsonl" \
  --data-binary @"$FILE"
echo
