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
# tags_mode entfällt – wir entscheiden allein anhand pos_tags/opt_tags
OUTPUT_FILE=""

# Konstanten
SCRIPT_DIR=""
REPO_ROOT=""
LOCK_FILE=""     # wird aus OUTPUT_FILE abgeleitet
TMP_LINE_FILE="" # explizit initialisieren
TMP_FEED_FILE=""

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
  if [[ -n "${TMP_LINE_FILE:-}" && -f "$TMP_LINE_FILE" ]]; then
    rm -f -- "$TMP_LINE_FILE"
  fi
  if [[ -n "${TMP_FEED_FILE:-}" && -f "$TMP_FEED_FILE" ]]; then
    rm -f -- "$TMP_FEED_FILE"
  fi
}
trap cleanup EXIT INT TERM

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

  # Speziell die Option -o vorab verarbeiten, um Testbarkeit zu erleichtern
  if [[ "${1:-}" == "-o" ]]; then
    OUTPUT_FILE="$2"
    shift 2
  fi

  if [[ "${1:-}" != "-"* && "$#" -ge 5 ]]; then
    # Positionsmodus
    source="$1"
    type="$2"
    title="$3"
    summary="$4"
    url="$5"
    shift 5
    mapfile -t pos_tags < <(printf '%s\n' "$@")
  else
    # Optionsmodus (getopts)
    # OPTIND zurücksetzen, falls die Funktion mehrfach aufgerufen wird
    OPTIND=1
    while getopts ":ho:t:s:T:S:u:g:" opt; do
      case "$opt" in
      h)
        print_usage
        exit 0
        ;;
      o) OUTPUT_FILE="$OPTARG" ;;
      t) type="$OPTARG" ;;
      s) source="$OPTARG" ;;
      T) title="$OPTARG" ;;
      S) summary="$OPTARG" ;;
      u) url="$OPTARG" ;;
      g) opt_tags="$OPTARG" ;;
      :)
        echo "Option -$OPTARG benötigt ein Argument." >&2
        print_usage
        exit 1
        ;;
      \?)
        echo "Unbekannte Option: -$OPTARG" >&2
        print_usage
        exit 1
        ;;
      esac
    done
  fi
}

validate_args() {
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

  case "$type" in
  news | sensor | project | alert) ;;
  *)
    echo "Fehler: type muss einer von {news|sensor|project|alert} sein." >&2
    exit 1
    ;;
  esac

  # Summary-Länge (max 500) – Bash zählt UTF-8-Zeichen korrekt bei passender Locale
  local summary_len
  summary="${summary:-""}"
  summary_len=${#summary}
  if ((summary_len > 500)); then
    echo "Fehler: summary darf höchstens 500 Zeichen umfassen (aktuell $summary_len)." >&2
    exit 1
  fi
}

build_tags_json() {
  # Tags: bevorzugt opt_tags, sonst pos_tags; immer Liste
  local -a tags_raw=()
  if [[ -n "${opt_tags:-}" ]]; then
    # Kommagetrennte Liste in Array wandeln
    IFS=',' read -r -a tags_raw <<<"$opt_tags"
  else
    tags_raw=("${pos_tags[@]}")
  fi

  if ((${#tags_raw[@]} == 0)); then
    echo '[]'
    return
  fi

  printf '%s\n' "${tags_raw[@]}" | jq -R 'select(length > 0)' | jq -s '
    map(gsub("^\\s+|\\s+$"; ""))
    | map(select(length > 0))
    | reduce .[] as $tag ([]; if index($tag) then . else . + [$tag] end)'
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
  TMP_LINE_FILE="$(safe_mktemp)"
  printf '%s\n' "$json_obj" >"$TMP_LINE_FILE"

  # Lokales Cleanup, falls vor dem mv abgebrochen wird
  TMP_FEED_FILE=""
  TMP_ACL_FILE=""
  TMP_XATTR_FILE=""
  cleanup_append() {
    if [[ -n "$TMP_LINE_FILE" && -f "$TMP_LINE_FILE" ]]; then
      rm -f -- "$TMP_LINE_FILE"
    fi
    if [[ -n "$TMP_FEED_FILE" && -f "$TMP_FEED_FILE" ]]; then
      rm -f -- "$TMP_FEED_FILE"
    fi
    if [[ -n "$TMP_ACL_FILE" && -f "$TMP_ACL_FILE" ]]; then
      rm -f -- "$TMP_ACL_FILE"
    fi
    if [[ -n "$TMP_XATTR_FILE" && -f "$TMP_XATTR_FILE" ]]; then
      rm -f -- "$TMP_XATTR_FILE"
    fi
  }
  trap cleanup_append EXIT INT TERM

  if have flock; then
    # Lock-basiertes, konkurrenzsicheres Anhängen
    exec 9>"$LOCK_FILE"
    local lock_timeout="${APPEND_LOCK_TIMEOUT:-10}"
    if flock -w "$lock_timeout" 9; then
      cat "$TMP_LINE_FILE" >>"$OUTPUT_FILE"
      flock -u 9
    else
      echo "Lock timeout auf $LOCK_FILE" >&2
      exit 1
    fi
    exec 9>&-
  else
    # Fallback ohne flock: atomar ersetzen und Metadaten der Originaldatei übernehmen.
    TMP_FEED_FILE="$(safe_mktemp)"

    if [[ -f "$OUTPUT_FILE" ]]; then
      # Inhalt übernehmen
      cp -f -- "$OUTPUT_FILE" "$TMP_FEED_FILE"
      # Basis-Metadaten klonen (Modus/Owner/Gruppe/Zeitstempel)
      chmod --reference="$OUTPUT_FILE" "$TMP_FEED_FILE" 2>/dev/null || true
      chown --reference="$OUTPUT_FILE" "$TMP_FEED_FILE" 2>/dev/null || true
      touch --reference="$OUTPUT_FILE" "$TMP_FEED_FILE" 2>/dev/null || true
      # SELinux-Kontext (optional)
      if command -v chcon >/dev/null 2>&1; then
        chcon --reference="$OUTPUT_FILE" "$TMP_FEED_FILE" 2>/dev/null || true
      fi

      # ACLs (optional)
      if command -v getfacl >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1; then
        TMP_ACL_FILE="$(safe_mktemp)"
        getfacl --absolute-names "$OUTPUT_FILE" 2>/dev/null > "$TMP_ACL_FILE"
        # Replace the file comment to reference the new file
        sed -i "1s|^# file: .*|# file: $TMP_FEED_FILE|" "$TMP_ACL_FILE"
        setfacl --restore="$TMP_ACL_FILE" 2>/dev/null || true
        rm -f -- "$TMP_ACL_FILE"
      fi

      # xattrs (optional)
      if command -v getfattr >/dev/null 2>&1 && command -v setfattr >/dev/null 2>&1; then
        TMP_XATTR_FILE="$(safe_mktemp)"
        getfattr -d -m - "$OUTPUT_FILE" 2>/dev/null > "$TMP_XATTR_FILE"
        # Replace or add file path comment as needed
        if grep -q '^# file: ' "$TMP_XATTR_FILE"; then
          sed -i "1s|^# file: .*|# file: $TMP_FEED_FILE|" "$TMP_XATTR_FILE"
        else
          sed -i "1i# file: $TMP_FEED_FILE" "$TMP_XATTR_FILE"
        fi
        setfattr --restore="$TMP_XATTR_FILE" 2>/dev/null || true
        rm -f -- "$TMP_XATTR_FILE"
      fi
    fi

    # Neue Zeile anhängen und dann atomar ersetzen
    cat "$TMP_LINE_FILE" >>"$TMP_FEED_FILE"
    mv -f -- "$TMP_FEED_FILE" "$OUTPUT_FILE"
  fi

  # Erfolgreich: Cleanup & Trap entfernen
  cleanup_append
  trap - EXIT INT TERM
}

main() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
