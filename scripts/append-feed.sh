#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<EOF
Usage: $(basename "$0") [-t type] [-s source] [-T title] [-S summary] [-u url] [-g tags]
Appends a JSON object to the feed.

  -t type       event type (default: news)
  -s source     event source (default: manual)
  -T title      event title (default: Untitled)
  -S summary    event summary (optional)
  -u url        event url (optional)
  -g tags       comma-separated tags (optional)
EOF
}

type="news"
source="manual"
title="Untitled"
summary=""
url=""
tags=""

while getopts "ht:s:T:S:u:g:" opt; do
  case "$opt" in
    h) print_usage; exit 0 ;;
    t) type="$OPTARG" ;;
    s) source="$OPTARG" ;;
    T) title="$OPTARG" ;;
    S) summary="$OPTARG" ;;
    u) url="$OPTARG" ;;
    g) tags="$OPTARG" ;;
    *) print_usage; exit 1 ;;
  esac
done

mkdir -p export
ts="$(date -Iseconds -u)"
json_obj=$(jq -n --arg ts "$ts" --arg type "$type" --arg source "$source" \
      --arg title "$title" --arg summary "$summary" --arg url "$url" \
      --arg tags "$tags" \
      '{
        "ts": $ts, "type": $type, "source": $source, "title": $title
      } +
      (if $summary != "" then {"summary": $summary} else {} end) +
      (if $url != "" then {"url": $url} else {} end) +
      (if $tags != "" then {"tags": ($tags | split(","))} else {} end)
      ')
if ! echo "$json_obj" | check-jsonschema --schemafile contracts/aussen.event.schema.json -; then
  echo "Validation failed" >&2
  exit 1
fi
echo "$json_obj" >> export/feed.jsonl
