#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Appends a JSON object to the feed.

Options:
  -o file      output file (default: export/feed.jsonl)
  -t type      event type (default: news)
  -s source    event source (default: manual)
  -T title     event title (default: Untitled)
  -S summary   event summary (optional)
  -u url       event url (optional)
  -g tags      comma-separated tags (optional)
  -h           show this help message and exit
USAGE
}

output_file="export/feed.jsonl"
type="news"
source="manual"
title="Untitled"
summary=""
url=""
tags=""

while getopts ":ho:t:s:T:S:u:g:" opt; do
  case "$opt" in
    h)
      print_usage
      exit 0
      ;;
    o)
      output_file="$OPTARG"
      ;;
    t)
      type="$OPTARG"
      ;;
    s)
      source="$OPTARG"
      ;;
    T)
      title="$OPTARG"
      ;;
    S)
      summary="$OPTARG"
      ;;
    u)
      url="$OPTARG"
      ;;
    g)
      tags="$OPTARG"
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      print_usage >&2
      exit 1
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(dirname "$output_file")"
ts="$(date -Iseconds -u)"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not installed." >&2
  exit 1
fi

if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "check-jsonschema is required but not installed." >&2
  exit 1
fi

tags_json=$(jq -cn --arg tags "$tags" '
  if $tags == "" then []
  else
    $tags
    | split(",")
    | map(. | gsub("^\\s+|\\s+$"; ""))
    | map(select(. != ""))
  end
')

json_obj=$(jq -n \
  --arg ts "$ts" \
  --arg type "$type" \
  --arg source "$source" \
  --arg title "$title" \
  --arg summary "$summary" \
  --arg url "$url" \
  --argjson tags "$tags_json" \
  '{
    ts: $ts,
    type: $type,
    source: $source,
    title: $title
  }
  + (if $summary != "" then {summary: $summary} else {} end)
  + (if $url != "" then {url: $url} else {} end)
  + (if ($tags | length) > 0 then {tags: $tags} else {} end)')

if ! echo "$json_obj" | check-jsonschema --schemafile contracts/aussen.event.schema.json --stdin-file -; then
  echo "Validation failed." >&2
  exit 1
fi

echo "Validation OK."

echo "$json_obj" >> "$output_file"
