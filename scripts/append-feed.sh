#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage: ./scripts/append-feed.sh <source> <type> <title> <summary> <url> [tags...]
  source  Menschlich lesbarer Bezeichner (z. B. heise, dwd)
  type    news|sensor|project|alert
  title   Titelzeile des Ereignisses
  summary Kurzbeschreibung (max. 500 Zeichen)
  url     Referenz-Link
  tags    Optionale Liste einzelner Tags (z. B. rss:demo klima)
USAGE
  exit 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "append-feed.sh benötigt jq (>=1.6)" >&2
  exit 1
fi

if [ "$#" -lt 5 ]; then
  usage
fi

source="$1"
type="$2"
title="$3"
summary="$4"
url="$5"
shift 5

tags=("$@")

if [[ -z "$source" || -z "$type" || -z "$title" || -z "$summary" || -z "$url" ]]; then
  echo "source, type, title, summary und url dürfen nicht leer sein" >&2
  exit 1
fi

case "$type" in
  news|sensor|project|alert) ;;
  *)
    echo "type muss einer von news|sensor|project|alert sein" >&2
    exit 1
    ;;
esac

summary_length=$(printf '%s' "$summary" | wc -m | tr -d '[:space:]')
if [ "$summary_length" -gt 500 ]; then
  echo "summary darf höchstens 500 Zeichen umfassen (aktuell $summary_length)" >&2
  exit 1
fi

if [ "${#tags[@]}" -gt 0 ]; then
  tags_json=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)
else
  tags_json='[]'
fi

ts="$(date -Iseconds -u)"

mkdir -p export

event=$(jq -nc \
  --arg ts "$ts" \
  --arg type "$type" \
  --arg source "$source" \
  --arg title "$title" \
  --arg summary "$summary" \
  --arg url "$url" \
  --argjson tags "$tags_json" \
  '{ts:$ts,type:$type,source:$source,title:$title,summary:$summary,url:$url,tags:$tags}')

printf '%s\n' "$event" >> export/feed.jsonl
