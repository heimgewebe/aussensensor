#!/usr/bin/env bash
set -euo pipefail
mkdir -p export
ts="$(date -Iseconds -u)"
jq -n --arg ts "$ts" --arg type "${1:-news}" --arg source "${2:-manual}" \
      --arg title "${3:-Untitled}" --arg summary "${4:-}" --arg url "${5:-}" \
      '{ts:$ts,type:$type,source:$source,title:$title,summary:$summary,url:$url}' \
  >> export/feed.jsonl
