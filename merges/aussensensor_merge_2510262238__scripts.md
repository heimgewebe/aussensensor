### 📄 scripts/append-feed.sh

**Größe:** 5 KB | **md5:** `01bb562813ca26725a6dae1c355d9c56`

```bash
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

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
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

  if ! printf '%s\n' "$json_obj" | "$SCRIPT_DIR/validate.sh"; then
    echo "Fehler: Das generierte Ereignis ist nicht valide." >&2
    echo "JSON-Objekt:" >&2
    echo "$json_obj" >&2
    exit 1
  fi
}

append_to_feed() {
  local json_obj="$1"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$json_obj" >> "$OUTPUT_FILE"
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
```

### 📄 scripts/jsonl-compact.sh

**Größe:** 608 B | **md5:** `987a2552c0a5532b7e2da696dcc2989a`

```bash
#!/usr/bin/env bash
set -euo pipefail
#
# Kompaktifiziert *.jsonl: jede Zeile = valides, kompaktes JSON-Objekt.
# Nutzung:
#   scripts/jsonl-compact.sh export/feed.jsonl
#
file="${1:-}"
[[ -n "$file" && -f "$file" ]] || { echo "usage: $0 <file.jsonl>" >&2; exit 2; }

tmp="$(mktemp "${file##*/}.XXXX")"
trap 'rm -f "$tmp"' EXIT

# Zeilenweise lesen, in kompaktes JSON (-c) konvertieren; invalide Zeilen brechen ab.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line// }" ]] || continue
  printf '%s\n' "$line" | jq -e -c . >>"$tmp"
done <"$file"

mv -f -- "$tmp" "$file"
echo "compacted: $file"
```

### 📄 scripts/push_heimlern.sh

**Größe:** 288 B | **md5:** `122ecddd60620babc32c37d75ecc2971`

```bash
#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-export/feed.jsonl}"
[[ -f "$FILE" ]] || { echo "missing $FILE"; exit 1; }
: "${HEIMLERN_INGEST_URL:?set HEIMLERN_INGEST_URL}"
curl -sS -X POST "$HEIMLERN_INGEST_URL" \
  -H "Content-Type: application/jsonl" \
  --data-binary @"$FILE"
echo
```

### 📄 scripts/push_leitstand.sh

**Größe:** 3 KB | **md5:** `31b4321770333a458d48fa98fd28c2ae`

```bash
#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: scripts/push_leitstand.sh [options]

Options:
  -f, --file PATH        Pfad zur JSONL-Datei (Standard: export/feed.jsonl)
      --url URL          Ziel-Endpoint (überschreibt $LEITSTAND_INGEST_URL)
      --token TOKEN      Authentifizierungs-Token (überschreibt $LEITSTAND_TOKEN)
      --content-type CT  Content-Type Header (Standard: $CONTENT_TYPE oder application/x-ndjson)
      --dry-run          Keine Übertragung, sondern nur Anzeige der Aktion
  -h, --help             Diese Hilfe anzeigen
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE_PATH="$REPO_ROOT/export/feed.jsonl"
INGEST_URL="${LEITSTAND_INGEST_URL:-}"
AUTH_TOKEN="${LEITSTAND_TOKEN:-}"
CONTENT_TYPE="${CONTENT_TYPE:-application/x-ndjson}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für $1" >&2; exit 1; }
      FILE_PATH="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --url" >&2; exit 1; }
      INGEST_URL="$2"
      shift 2
      ;;
    --token)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --token" >&2; exit 1; }
      AUTH_TOKEN="$2"
      shift 2
      ;;
    --content-type)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --content-type" >&2; exit 1; }
      CONTENT_TYPE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INGEST_URL" ]]; then
  echo "Fehler: LEITSTAND_INGEST_URL ist nicht gesetzt und --url wurde nicht übergeben." >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "Fehler: Datei '$FILE_PATH' nicht gefunden." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Fehlt: curl" >&2
  exit 1
fi

event_count=0
if [[ -f "$FILE_PATH" ]]; then
  event_count="$(grep -cve '^\s*$' "$FILE_PATH" 2>/dev/null || echo 0)"
fi

if [[ ! -s "$FILE_PATH" ]]; then
  echo "Warnung: Datei '$FILE_PATH' ist leer." >&2
fi

if [[ -z "${CONTENT_TYPE//[[:space:]]/}" ]]; then
  echo "Fehler: Content-Type ist leer." >&2
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] Würde $event_count Ereignis(se) an '$INGEST_URL' übertragen." >&2
  echo "[DRY-RUN] Datei: $FILE_PATH" >&2
  if [[ -n "$AUTH_TOKEN" ]]; then
    echo "[DRY-RUN] Token: gesetzt (${#AUTH_TOKEN} Zeichen)." >&2
  else
    echo "[DRY-RUN] Token: nicht gesetzt." >&2
  fi
  echo "[DRY-RUN] Content-Type: $CONTENT_TYPE" >&2
  if [[ -f "$FILE_PATH" ]]; then
    head -n5 "$FILE_PATH" >&2 || true
  fi
  exit 0
fi

curl_args=(
  --fail
  --silent
  --show-error
  --request POST
  --header "Content-Type: $CONTENT_TYPE"
  --data-binary "@$FILE_PATH"
)

if [[ -n "$AUTH_TOKEN" ]]; then
  curl_args+=(--header "x-auth: $AUTH_TOKEN")
fi

curl "${curl_args[@]}" "$INGEST_URL"
printf '\nOK: Feed an %s gesendet.\n' "$INGEST_URL" >&2
```

### 📄 scripts/validate.sh

**Größe:** 2 KB | **md5:** `ce2269db1f2a9cf406cc5ad60f0e93a2`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [file.jsonl]
    Validiert jede Zeile der angegebenen Datei.

  <json-producer> | ./scripts/validate.sh
    Validiert das JSON-Objekt von stdin.
USAGE
}

# --- Main --------------------------------------------------------------------

need npx

# Temporäre Datei für die Validierung erstellen und Bereinigung sicherstellen
TMP_EVENT_FILE="$(mktemp /tmp/aussen_event.XXXX.json)"
trap 'rm -f "$TMP_EVENT_FILE"' EXIT

validate_line() {
  local line="$1"
  local context="$2"

  # Leere Zeilen ignorieren
  [[ -z "${line// }" ]] && return 0

  printf '%s\n' "$line" > "$TMP_EVENT_FILE"

  if ! npx -y ajv-cli@5 validate \
    --spec=draft2020 \
    --strict=false \
    --validate-formats=false \
    -s "$SCHEMA_PATH" \
    -d "$TMP_EVENT_FILE" >/dev/null; then
    echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
    # Zeige die ausführliche Fehlermeldung von ajv
    npx -y ajv-cli@5 validate \
      --spec=draft2020 \
      --strict=false \
      --validate-formats=false \
      -s "$SCHEMA_PATH" \
      -d "$TMP_EVENT_FILE"
    exit 1
  fi
}

if [[ $# -gt 0 && -f "$1" ]]; then
  # Datei-Modus
  FILE_TO_CHECK="$1"
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "Zeile $line_num in '$FILE_TO_CHECK'"
  done < "$FILE_TO_CHECK"
  echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."

elif [[ $# -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "stdin (Zeile $line_num)"
  done
  echo "OK: Stdin-Daten sind valide."
else
  print_usage
  exit 1
fi
```

