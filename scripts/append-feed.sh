#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'USAGE' >&2
Usage:
  Positional:
    ./scripts/append-feed.sh <source> <type> <title> <summary> <url> [tags...]
      source   Menschlich lesbarer Bezeichner (z. B. heise, dwd)
      type     news|sensor|project|alert
      title    Titelzeile des Ereignisses
      summary  Kurzbeschreibung (max. 500 Zeichen)
      url      Referenz-Link
      tags     Optionale Liste einzelner Tags (einzelne Tokens, z. B. rss:demo klima)

  Optionen:
    -o file    Ausgabe-Datei (NDJSON). Standard: export/feed.jsonl
    -t type    Ereignistyp (news|sensor|project|alert). Standard: news
    -s source  Quelle (z. B. heise). Standard: manual
    -T title   Titel (erforderlich im Optionsmodus)
    -S summary Kurztext (optional, ≤ 500 Zeichen)
    -u url     Referenz-URL (optional)
    -g tags    Kommagetrennte Tags (z. B. "rss:demo, klima")
    -h         Hilfe anzeigen
USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
OUTPUT_FILE="$REPO_ROOT/export/feed.jsonl"

# --- Parameter-Parsen (Dual-Modus) -------------------------------------------

declare -a pos_tags=()

if [[ "${1:-}" != "-"* && "$#" -ge 5 ]]; then
  # Positionsmodus
  source="$1"; type="$2"; title="$3"; summary="$4"; url="$5"; shift 5
  mapfile -t pos_tags < <(printf '%s\n' "$@")
  tags_mode="positional"
else
  # Optionsmodus (getopts)
  type="news"
  source="manual"
  title=""
  summary=""
  url=""
  opt_tags=""
  while getopts ":ho:t:s:T:S:u:g:" opt; do
    case "$opt" in
      h) print_usage; exit 0 ;;
      o) OUTPUT_FILE="$OPTARG" ;;
      t) type="$OPTARG" ;;
      s) source="$OPTARG" ;;
      T) title="$OPTARG" ;;
      S) summary="$OPTARG" ;;
      u) url="$OPTARG" ;;
      g) opt_tags="$OPTARG" ;;
      :) echo "Option -$OPTARG benötigt ein Argument." >&2; print_usage; exit 1 ;;
      \?) echo "Unbekannte Option: -$OPTARG" >&2; print_usage; exit 1 ;;
    esac
  done
  tags_mode="getopts"
fi

# --- Validierungen -----------------------------------------------------------

if [[ -z "${source:-}" || -z "${type:-}" || -z "${title:-}" ]]; then
  echo "Fehler: source, type und title dürfen nicht leer sein." >&2
  print_usage
  exit 1
fi

case "$type" in
  news|sensor|project|alert) ;;
  *) echo "Fehler: type muss einer von {news|sensor|project|alert} sein." >&2; exit 1 ;;
esac

if [[ -n "${summary:-}" ]]; then
  # Zeichen zählen ohne nachfolgende Whitespaces von wc
  summary_len="$(printf '%s' "$summary" | wc -m | tr -d '[:space:]')"
  if (( summary_len > 500 )); then
    echo "Fehler: summary darf höchstens 500 Zeichen umfassen (aktuell $summary_len)." >&2
    exit 1
  fi
fi

# --- Tags in JSON umwandeln --------------------------------------------------

need jq

if [[ "${tags_mode:-}" == "positional" ]]; then
  if (( ${#pos_tags[@]} > 0 )); then
    tags_json="$(printf '%s\n' "${pos_tags[@]}" | jq -R 'select(length > 0)' | jq -s .)"
  else
    tags_json='[]'
  fi
else
  # getopts: Kommagetrennt -> Array
  tags_json="$(jq -cn --arg tags "${opt_tags:-}" '
    if $tags == "" then []
    else
      $tags
      | split(",")
      | map(. | gsub("^\\s+|\\s+$"; ""))
      | map(select(. != ""))
    end')"
fi

# --- Ereignis bauen ----------------------------------------------------------

ts="$(date -Iseconds -u)"
mkdir -p "$(dirname "$OUTPUT_FILE")"

json_obj="$(
  jq -cn \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg source "$source" \
    --arg title "$title" \
    --arg summary "${summary:-}" \
    --arg url "${url:-}" \
    --argjson tags "$tags_json" \
    '{
      ts: $ts,
      type: $type,
      source: $source,
      title: $title,
      summary: ($summary // ""),
      url: ($url // ""),
      tags: ($tags // [])
    }'
)"

# --- Schema-Validierung (stdin korrekt angeben) ------------------------------
need check-jsonschema
# WICHTIG: --stdin-file aktivieren; kein '-' als Pseudo-Dateiname übergeben.
#          Damit liest check-jsonschema zuverlässig von stdin.
if ! printf '%s' "$json_obj" | check-jsonschema --schemafile "$SCHEMA_PATH" --stdin-file stdin >/dev/null; then
  echo "Validation failed." >&2
  exit 1
fi

# --- Append ------------------------------------------------------------------

printf '%s\n' "$json_obj" >> "$OUTPUT_FILE"
echo "OK: Ereignis in '$OUTPUT_FILE' angehängt."

exit 0
