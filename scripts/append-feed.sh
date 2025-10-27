#!/usr/bin/env bash
set -euo pipefail

# --- Globale Variablen und Konstanten --------------------------------------

# Diese Variablen werden von parse_args gesetzt und von anderen Funktionen verwendet.
source=""
type=""
title=""
summary=""
url=""
declare -a pos_tags=()
opt_tags=""
tags_mode=""
OUTPUT_FILE=""

# Konstanten
SCRIPT_DIR=""
REPO_ROOT=""
SCHEMA_PATH=""
LOCK_FILE=""     # wird aus OUTPUT_FILE abgeleitet

have() { command -v "$1" >/dev/null 2>&1; }
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehlt: $1" >&2
    exit 1
  fi
}
uuid() { if have uuidgen; then uuidgen; else echo "$RANDOM-$RANDOM-$$-$(date +%s%N)"; fi; }
safe_mktemp() { mktemp "${TMPDIR:-/tmp}/aussen_append.$(uuid).XXXXXX"; }


# --- Funktionen ------------------------------------------------------------

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

parse_args() {
  # Default-Werte setzen, bevor die Argumente verarbeitet werden.
  type="news"
  source="manual"
  title=""
  summary=""
  url=""
  opt_tags=""

  if [[ "${1:-}" != "-"* && "$#" -ge 5 ]]; then
    # Positionsmodus
    source="$1"; type="$2"; title="$3"; summary="$4"; url="$5"; shift 5
    mapfile -t pos_tags < <(printf '%s\n' "$@")
    tags_mode="positional"
  else
    # Optionsmodus (getopts)
    # OPTIND zurücksetzen, falls die Funktion mehrfach aufgerufen wird
    OPTIND=1
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
}

validate_args() {
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
    # Zeichen zählen, ohne Leerzeichen aus dem Inhalt zu entfernen
    local summary_len
    summary_len="$(printf '%s' "$summary" | wc -m | xargs)"
    if (( summary_len > 500 )); then
      echo "Fehler: summary darf höchstens 500 Zeichen umfassen (aktuell $summary_len)." >&2
      exit 1
    fi
  fi
}

build_tags_json() {
  if [[ "${tags_mode:-}" == "positional" ]]; then
    if (( ${#pos_tags[@]} > 0 )); then
      printf '%s\n' "${pos_tags[@]}" | jq -R 'select(length > 0)' | jq -s .
    else
      echo '[]'
    fi
  else
    # getopts: Kommagetrennt -> Array
    jq -cn --arg tags "${opt_tags:-}" '
      if $tags == "" then []
      else
        $tags
        | split(",")
        | map(. | gsub("^\\s+|\\s+$"; ""))
        | map(select(. != ""))
      end'
  fi
}

build_json() {
  local tags_json
  tags_json=$(build_tags_json)
  local ts
  ts="$(date -Iseconds -u)"

  jq -cn \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg source "$source" \
    --arg title "$title" \
    --arg summary "${summary:-}" \
    --arg url "${url:-}" \
    --argjson tags "$tags_json" \
    '{
      "ts": $ts,
      "type": $type,
      "source": $source,
      "title": $title,
      "summary": ($summary // ""),
      "url": ($url // ""),
      "tags": ($tags // [])
    }'
}

validate_json_schema() {
  local json_obj="$1"
  local validator="$SCRIPT_DIR/validate.sh"

  if [[ ! -x "$validator" ]]; then
    echo "Validation script not found: $validator" >&2
    exit 1
  fi

  if ! printf '%s\n' "$json_obj" | "$validator" >/dev/null; then
    echo "Fehler: Das generierte Ereignis ist nicht valide." >&2
    echo "JSON-Objekt:" >&2
    echo "$json_obj" >&2
    exit 1
  fi
}

append_to_feed() {
  local json_obj="$1"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  LOCK_FILE="${OUTPUT_FILE}.lock"

  # Schreibe erst in eine temporäre Datei (immer eine komplette Zeile, mit \n)
  local tmp_line=""
  local tmp_feed=""
  cleanup() {
    if [[ -n "$tmp_line" && -f "$tmp_line" ]]; then
      rm -f -- "$tmp_line"
    fi
    if [[ -n "$tmp_feed" && -f "$tmp_feed" ]]; then
      rm -f -- "$tmp_feed"
    fi
  }
  trap cleanup EXIT INT TERM

  tmp_line="$(safe_mktemp)"
  printf '%s\n' "$json_obj" > "$tmp_line"

  if have flock; then
    # Lock-basiertes, konkurrenzsicheres Anhängen
    exec 9>"$LOCK_FILE"
    local lock_timeout="${APPEND_LOCK_TIMEOUT:-10}"
    echo "append-feed: Verwende flock mit Timeout ${lock_timeout}s" >&2
    if flock -w "$lock_timeout" 9; then
      cat "$tmp_line" >> "$OUTPUT_FILE"
      flock -u 9
    else
      echo "Lock timeout auf $LOCK_FILE" >&2
      cleanup
      exit 1
    fi
    exec 9>&-
  else
    # Fallback ohne flock: anhängen via atomarem Replace
    # 1) Bestehenden Feed in temp kopieren (falls vorhanden)
    echo "append-feed: flock nicht verfügbar, verwende atomaren Fallback" >&2
    tmp_feed="$(safe_mktemp)"
    if [[ -f "$OUTPUT_FILE" ]]; then
      cp -f -- "$OUTPUT_FILE" "$tmp_feed"
    fi
    cat "$tmp_line" >> "$tmp_feed"
    mv -f "$tmp_feed" "$OUTPUT_FILE"
  fi
  cleanup
  trap - EXIT INT TERM
}

main() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
  # Default output file, can be overwritten by -o flag
  OUTPUT_FILE="$REPO_ROOT/export/feed.jsonl"

  need date
  need jq
  need wc
  need xargs

  parse_args "$@"
  validate_args

  local json_obj
  json_obj=$(build_json)

  validate_json_schema "$json_obj"
  append_to_feed "$json_obj"

  echo "OK: Ereignis in '$OUTPUT_FILE' angehängt."
}

# --- Skriptausführung --------------------------------------------------------

# Führe main aus, es sei denn, das Skript wird nur "gesourced"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
