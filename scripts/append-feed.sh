#!/usr/bin/env bash
set -euo pipefail

# Set default output file
output_file="export/feed.jsonl"

# If the first argument is -o, then the second argument is the output file
if [[ "${1:-}" == "-o" ]]; then
  output_file="$2"
  shift 2
fi

mkdir -p "$(dirname "$output_file")"
ts="$(date -Iseconds -u)"

# Set default values
type="news"
source="manual"
title="Untitled"
summary=""
url=""
tags_arr=()

# Process arguments
if [[ $# -gt 0 ]]; then type="$1"; shift; fi
if [[ $# -gt 0 ]]; then source="$1"; shift; fi
if [[ $# -gt 0 ]]; then title="$1"; shift; fi
if [[ $# -gt 0 ]]; then summary="$1"; shift; fi
if [[ $# -gt 0 ]]; then url="$1"; shift; fi
if [[ $# -gt 0 ]]; then
  tags_arr=("$@")
fi

tags_json=$(jq -n '$ARGS.positional' --args "${tags_arr[@]}")

jq -n --arg ts "$ts" --arg type "$type" --arg source "$source" \
      --arg title "$title" --arg summary "$summary" --arg url "$url" \
      --argjson tags "$tags_json" \
      '{ts:$ts,type:$type,source:$source,title:$title,summary:$summary,url:$url,tags:$tags}' \
  >> "$output_file"