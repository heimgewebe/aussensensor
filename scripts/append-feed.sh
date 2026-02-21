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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE=""     # wird aus OUTPUT_FILE abgeleitet
TMP_LINE_FILE="" # explizit initialisieren
LOCK_DIR=""      # für Fallback-Locking
ALLOWED_TYPES=("news" "sensor" "project" "alert" "link")

# shellcheck source=scripts/utils.sh
source "$SCRIPT_DIR/utils.sh"
# Generiert eine eindeutige ID für temporäre Dateinamen.
# Hinweis: Format variiert je nach Tool (UUID vs. Hex-String), ist aber für diesen Zweck hinreichend kollisionssicher.
tmp_id() {
  # Allow tests to force fallback without brittle sed patching.
  # Set to 1 to disable individual sources.
  local disable_uuidgen="${AUSSEN_DISABLE_UUIDGEN:-0}"
  local disable_openssl="${AUSSEN_DISABLE_OPENSSL:-0}"
  local disable_python3="${AUSSEN_DISABLE_PYTHON3:-0}"

  if [[ "$disable_uuidgen" != "1" ]] && have uuidgen; then
    uuidgen
  elif [[ "$disable_openssl" != "1" ]] && have openssl; then
    openssl rand -hex 16
  elif [[ "$disable_python3" != "1" ]] && have python3; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    echo "$RANDOM-$RANDOM-$$-$(date +%s)"
  fi
}

trim() {
  # Usage: trim "   string   "
  # Removes leading and trailing whitespace (space, tab, newline).
  local s="$1"
  # Remove leading whitespace
  s="${s#"${s%%[![:space:]]*}"}"
  # Remove trailing whitespace
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

safe_mktemp() { mktemp "${TMPDIR:-/tmp}/aussen_append.$(tmp_id).XXXXXX"; }

cleanup() {
  # Stellt sicher, dass temporäre Dateien bei Skript-Ende gelöscht werden.
  [[ -n "${TMP_LINE_FILE:-}" && -f "$TMP_LINE_FILE" ]] && rm -f -- "$TMP_LINE_FILE"
  # Fallback-Lock aufräumen
  [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" ]] && rmdir "$LOCK_DIR"
  return 0
}
trap cleanup EXIT

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
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      output_arg="$2"
      shift 2
      ;;
    --output=*)
      output_arg="${1#*=}"
      shift
      ;;
    -t | --type)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      type_arg="$2"
      shift 2
      ;;
    --type=*)
      type_arg="${1#*=}"
      shift
      ;;
    -s | --source)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      source_arg="$2"
      shift 2
      ;;
    --source=*)
      source_arg="${1#*=}"
      shift
      ;;
    -T | --title)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      title_arg="$2"
      shift 2
      ;;
    --title=*)
      title_arg="${1#*=}"
      shift
      ;;
    -S | --summary)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      summary_arg="$2"
      shift 2
      ;;
    --summary=*)
      summary_arg="${1#*=}"
      shift
      ;;
    -u | --url)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
      url_arg="$2"
      shift 2
      ;;
    --url=*)
      url_arg="${1#*=}"
      shift
      ;;
    -g | --tags)
      [[ $# -ge 2 ]] || { echo "Fehler: Fehlender Parameter für $1" >&2; exit 1; }
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
      local pos_idx=0

      if [[ -z "$source_arg" && $pos_idx -lt ${#positional[@]} ]]; then
          source="${positional[$pos_idx]}"
          ((pos_idx++)) || true
      fi
      if [[ -z "$type_arg" && $pos_idx -lt ${#positional[@]} ]]; then
          type="${positional[$pos_idx]}"
          ((pos_idx++)) || true
      fi
      if [[ -z "$title_arg" && $pos_idx -lt ${#positional[@]} ]]; then
          title="${positional[$pos_idx]}"
          ((pos_idx++)) || true
      fi
      if [[ -z "$summary_arg" && $pos_idx -lt ${#positional[@]} ]]; then
          summary="${positional[$pos_idx]}"
          ((pos_idx++)) || true
      fi
      if [[ -z "$url_arg" && $pos_idx -lt ${#positional[@]} ]]; then
          url="${positional[$pos_idx]}"
          ((pos_idx++)) || true
      fi

      # Verbleibende Argumente sind Tags (ohne leere/whitespace Tags)
      while [[ $pos_idx -lt ${#positional[@]} ]]; do
          local tag="${positional[$pos_idx]}"
          # Trim whitespace directly
          tag="$(trim "$tag")"
          [[ -n "$tag" ]] && tags_array+=("$tag")
          ((pos_idx++)) || true
      done
  fi

  # Merge tags from -g/--tags
  if [[ -n "$tags_raw" ]]; then
      IFS=',' read -r -a extra_tags <<< "$tags_raw"
      for tag in "${extra_tags[@]}"; do
          tag="$(trim "$tag")"
          [[ -n "$tag" ]] && tags_array+=("$tag")
      done
  fi

  # Deduplicate tags
  if [[ ${#tags_array[@]} -gt 0 ]]; then
      declare -A seen
      declare -a unique_tags=()
      for tag in "${tags_array[@]}"; do
          # Trim whitespace
          tag_trimmed="$(trim "$tag")"
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

  if [[ -z "${source//[[:space:]]/}" || -z "${type//[[:space:]]/}" || -z "${title//[[:space:]]/}" ]]; then
    echo "Fehler: source/type/title dürfen nicht nur aus Leerzeichen bestehen." >&2
    print_usage
    exit 1
  fi

  if [[ "$source" == "-" || "$type" == "-" || "$title" == "-" ]]; then
    echo "Fehler: '-' ist kein gültiger Wert für source/type/title." >&2
    print_usage
    exit 1
  fi

  local type_allowed=0
  for allowed in "${ALLOWED_TYPES[@]}"; do
    if [[ "$type" == "$allowed" ]]; then
      type_allowed=1
      break
    fi
  done
  if [[ "$type_allowed" -ne 1 ]]; then
    local allowed_types_string
    allowed_types_string="$(IFS=','; echo "${ALLOWED_TYPES[*]}")"
    echo "Fehler: type muss einer der folgenden Werte sein: ${allowed_types_string}." >&2
    print_usage
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
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Convert tags array to JSON array
  local tags_json="[]"
  if [[ ${#tags_array[@]} -gt 0 ]]; then
      tags_json="$(printf '%s\n' "${tags_array[@]}" | jq -R . | jq -s .)"
  fi

  # Build base object
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
      "tags": ($tags // [])
    } + (if $url != "" then {"url": $url} else {} end)'
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
    # Fallback ohne flock: mkdir-basiertes Locking (portabel und sicher)
    LOCK_DIR="${OUTPUT_FILE}.lock.d"
    local retries=0
    local max_retries=50

    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
      if ((retries >= max_retries)); then
        echo "Fehler: Lock timeout auf $LOCK_DIR" >&2
        exit 1
      fi
      # Versuche sub-second sleep, fallback auf 1s
      sleep 0.1 2>/dev/null || sleep 1
      ((retries+=1))
    done

    # Kritischer Abschnitt
    cat "$TMP_LINE_FILE" >>"$OUTPUT_FILE"

    rmdir "$LOCK_DIR"
    LOCK_DIR="" # Reset nach erfolgreichem Release
  fi
}

main() {
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
