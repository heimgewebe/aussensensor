#!/usr/bin/env bash
set -euo pipefail

# --- Globale Variablen und Konstanten --------------------------------------

source=""
type="news"
title=""
summary=""
url=""
declare -a tags_array=()
OUTPUT_FILE=""

# Konstanten
SCRIPT_DIR=""
REPO_ROOT=""
LOCK_FILE=""     # wird aus OUTPUT_FILE abgeleitet
TMP_LINE_FILE="" # explizit initialisieren

have() { command -v "$1" >/dev/null 2>&1; }
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehlt: $1" >&2
    exit 1
  fi
}
uuid() { if have uuidgen; then uuidgen; else echo "$RANDOM-$RANDOM-$$-$(date +%s%N)"; fi; }
safe_mktemp() { mktemp "${TMPDIR:-/tmp}/aussen_append.$(uuid).XXXXXX"; }

cleanup() {
  # Stellt sicher, dass temporäre Dateien bei Skript-Ende gelöscht werden.
  [[ -n "${TMP_LINE_FILE:-}" && -f "$TMP_LINE_FILE" ]] && rm -f -- "$TMP_LINE_FILE"
  return 0
}
trap cleanup EXIT INT TERM

# --- Funktionen ------------------------------------------------------------

print_usage() {
  cat <<'USAGE' >&2
Usage:
  Positional:
    ./scripts/append-feed.sh <source> <type> <title> <summary> <url> [tags...]

  Optionen:
    -o, --output file    Ausgabe-Datei (NDJSON). Standard: export/feed.jsonl
    -t, --type type      Ereignistyp (z.B. news, sensor, project, alert). Standard: news
    -s, --source source  Quelle (z. B. heise). Standard: manual
    -T, --title title    Titel (erforderlich im Optionsmodus)
    -S, --summary text   Kurztext (optional, ≤ 2000 Zeichen)
    -u, --url url        Referenz-URL (optional)
    -g, --tags tags      Kommagetrennte Tags (z. B. "rss:demo, klima")
    -h, --help           Hilfe anzeigen
USAGE
}

parse_args() {
  # Default-Werte sind oben global definiert
  local source_arg=""
  local type_arg=""
  local title_arg=""
  local summary_arg=""
  local url_arg=""
  local tags_raw=""
  local output_arg=""

  # Flags flag tracking to handle mixed usage if needed,
  # but typically we either use flags or purely positional.
  # We'll allow flags to override defaults, and positional args to fill gaps if flags aren't used for them.

  declare -a positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      print_usage
      exit 0
      ;;
    -o | --output)
      output_arg="$2"
      shift 2
      ;;
    --output=*)
      output_arg="${1#*=}"
      shift
      ;;
    -t | --type)
      type_arg="$2"
      shift 2
      ;;
    --type=*)
      type_arg="${1#*=}"
      shift
      ;;
    -s | --source)
      source_arg="$2"
      shift 2
      ;;
    --source=*)
      source_arg="${1#*=}"
      shift
      ;;
    -T | --title)
      title_arg="$2"
      shift 2
      ;;
    --title=*)
      title_arg="${1#*=}"
      shift
      ;;
    -S | --summary)
      summary_arg="$2"
      shift 2
      ;;
    --summary=*)
      summary_arg="${1#*=}"
      shift
      ;;
    -u | --url)
      url_arg="$2"
      shift 2
      ;;
    --url=*)
      url_arg="${1#*=}"
      shift
      ;;
    -g | --tags)
      tags_raw="$2"
      shift 2
      ;;
    --tags=*)
      tags_raw="${1#*=}"
      shift
      ;;
    -*)
      echo "Unbekannte Option: $1" >&2
      print_usage
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
    esac
  done

  # Apply parsed flags
  [[ -n "$output_arg" ]] && OUTPUT_FILE="$output_arg"
  [[ -n "$source_arg" ]] && source="$source_arg"
  [[ -n "$type_arg" ]] && type="$type_arg"
  [[ -n "$title_arg" ]] && title="$title_arg"
  [[ -n "$summary_arg" ]] && summary="$summary_arg"
  [[ -n "$url_arg" ]] && url="$url_arg"

  # Handle positional arguments if flags were not sufficient or strictly positional mode
  if [[ ${#positional[@]} -gt 0 ]]; then
      # If we have 5+ positional args, assume full positional mode for missing fields
      if [[ ${#positional[@]} -ge 5 ]]; then
          [[ -z "$source_arg" ]] && source="${positional[0]}"
          [[ -z "$type_arg" ]] && type="${positional[1]}"
          [[ -z "$title_arg" ]] && title="${positional[2]}"
          [[ -z "$summary_arg" ]] && summary="${positional[3]}"
          [[ -z "$url_arg" ]] && url="${positional[4]}"

          # Any remaining positional args are tags
          if [[ ${#positional[@]} -gt 5 ]]; then
              tags_array+=("${positional[@]:5}")
          fi
      else
          # Fallback: Treat as error or partial fill?
          # Existing tests suggest we either use full positional or flags.
          # If we have some positional but less than 5, and no flags, it's likely an error.
          # But if we have flags, maybe we ignore positional?
          # Let's assume if flags are used, positional args might be tags if provided?
          # Or simply: if source is still empty, try to fill from positional?
          # For safety/legacy compatibility:
          if [[ -z "$source_arg" && -z "$title_arg" ]]; then
               # Likely incomplete positional usage
               :
          fi
      fi
  fi

  # Merge tags from -g/--tags
  if [[ -n "$tags_raw" ]]; then
      IFS=',' read -r -a extra_tags <<< "$tags_raw"
      tags_array+=("${extra_tags[@]}")
  fi

  # Deduplicate tags
  if [[ ${#tags_array[@]} -gt 0 ]]; then
      declare -A seen
      declare -a unique_tags=()
      for tag in "${tags_array[@]}"; do
          # Trim whitespace
          tag_trimmed="$(echo "$tag" | xargs)"
          if [[ -n "$tag_trimmed" && -z "${seen[$tag_trimmed]:-}" ]]; then
              unique_tags+=("$tag_trimmed")
              seen["$tag_trimmed"]=1
          fi
      done
      tags_array=("${unique_tags[@]}")
  fi
}

validate_args() {
  # Default source to manual if not set (legacy behavior was in parse_args init)
  [[ -z "$source" ]] && source="manual"

  if [[ -z "${source:-}" || -z "${type:-}" || -z "${title:-}" ]]; then
    echo "Fehler: source, type und title dürfen nicht leer sein." >&2
    print_usage
    exit 1
  fi

  if [[ -z "${source//[[:space:]]/}" || -z "${title//[[:space:]]/}" ]]; then
    echo "Fehler: source/title dürfen nicht nur aus Leerzeichen bestehen." >&2
    exit 1
  fi

  if [[ "$source" == "-" || "$title" == "-" ]]; then
    echo "Fehler: '-' ist kein gültiger Wert für source/title." >&2
    exit 1
  fi

  # Summary-Länge (max 2000)
  local summary_len
  summary="${summary:-""}"
  summary_len=${#summary}
  if ((summary_len > 2000)); then
    echo "Fehler: summary darf höchstens 2000 Zeichen umfassen (aktuell $summary_len)." >&2
    exit 1
  fi
}

build_json() {
  local ts
  ts="$(date -Iseconds -u)"

  # Convert tags array to JSON array
  local tags_json="[]"
  if [[ ${#tags_array[@]} -gt 0 ]]; then
      tags_json="$(printf '%s\n' "${tags_array[@]}" | jq -R . | jq -s .)"
  fi

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
  TMP_LINE_FILE="$(safe_mktemp)"
  printf '%s\n' "$json_obj" >"$TMP_LINE_FILE"

  if have flock; then
    # Lock-basiertes, konkurrenzsicheres Anhängen
    exec 9>"$LOCK_FILE"
    local lock_timeout="${APPEND_LOCK_TIMEOUT:-10}"
    if flock -w "$lock_timeout" 9; then
      cat "$TMP_LINE_FILE" >>"$OUTPUT_FILE"
      flock -u 9
    else
      echo "Fehler: Lock timeout auf $LOCK_FILE" >&2
      exit 1
    fi
    exec 9>&-
  else
    # Fallback ohne flock: atomar ersetzen mit Basis-Metadaten
    TMP_FEED_FILE="$(safe_mktemp)"

    if [[ -f "$OUTPUT_FILE" ]]; then
      # Inhalt und Basis-Metadaten übernehmen
      cp -p -- "$OUTPUT_FILE" "$TMP_FEED_FILE"
    fi

    # Neue Zeile anhängen und dann atomar ersetzen
    cat "$TMP_LINE_FILE" >>"$TMP_FEED_FILE"
    mv -f -- "$TMP_FEED_FILE" "$OUTPUT_FILE"
  fi
}

main() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  # Default output file, can be overwritten by -o flag
  OUTPUT_FILE="$REPO_ROOT/export/feed.jsonl"

  need date
  need jq

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
