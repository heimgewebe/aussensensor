#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
STRICT="${STRICT:-false}"
VALIDATE_FORMATS="${VALIDATE_FORMATS:-false}"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"
TMP_EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.validate.XXXXXX.json")"
cleanup() { rm -f "$TMP_EVENT_FILE"; }
trap cleanup EXIT INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [-s|--schema PATH] [file.jsonl ...]
    Validiert jede Zeile der angegebenen Datei(en).

  <json-producer> | ./scripts/validate.sh [-s|--schema PATH]
    Validiert das JSON-Objekt von stdin.

Umgebungsvariablen:
  STRICT=true             Aktiviert strikte Validierung von ajv.
  VALIDATE_FORMATS=true   Prüft Format-Validierungen.
  REQUIRE_NONEMPTY=1      Fehler bei leeren Dateien oder leerem stdin.

Beispiele:
  STRICT=true VALIDATE_FORMATS=true \
    ./scripts/validate.sh -s contracts/aussen.event.schema.json export/feed.jsonl
USAGE
}

# --- Main --------------------------------------------------------------------

need npx

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--schema)
      if [[ $# -lt 2 ]]; then
        echo "Fehler: --schema benötigt einen Pfad." >&2
        print_usage
        exit 1
      fi
      SCHEMA_FILE="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unbekannte Option: $1" >&2
      print_usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Schema nicht gefunden: $SCHEMA_FILE" >&2
  exit 1
fi

declare -a FILES_TO_CHECK=()
while [[ $# -gt 0 ]]; do
  FILES_TO_CHECK+=("$1")
  shift
done

validate_line() {
  local line="$1"
  local context="${2:-stdin}"

  # Leere Zeilen ignorieren
  [[ -z "${line// }" ]] && return 0

  printf '%s\n' "$line" > "$TMP_EVENT_FILE"

  local ajv_output
  local -a ajv_cmd=(
    npx -y ajv-cli@5.0.0 validate
    --spec=draft2020
    --strict="$STRICT"
    --validate-formats="$VALIDATE_FORMATS"
    -s "$SCHEMA_FILE"
    -d "$TMP_EVENT_FILE"
  )

  if ! ajv_output="$("${ajv_cmd[@]}" 2>&1)"; then
    echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
    printf '%s\n' "$ajv_output" >&2
    exit 1
  fi
}

if [[ ${#FILES_TO_CHECK[@]} -gt 0 ]]; then
  status=0
  for FILE_TO_CHECK in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$FILE_TO_CHECK" ]]; then
      echo "Fehlt: $FILE_TO_CHECK" >&2
      status=1
      continue
    fi

    line_num=0
    seen=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_num=$((line_num + 1))
      [[ -z "${line// }" ]] || seen=1
      validate_line "$line" "Zeile $line_num in '$FILE_TO_CHECK'"
    done < "$FILE_TO_CHECK"

    if [[ $seen -eq 0 ]]; then
      if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
        echo "❌ Keine Ereignisse zur Validierung in '$FILE_TO_CHECK' (REQUIRE_NONEMPTY=1)" >&2
        status=1
      else
        echo "⚠️  Keine Ereignisse zur Validierung in '$FILE_TO_CHECK'" >&2
      fi
    else
      echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."
    fi
  done
  exit $status

elif [[ ${#FILES_TO_CHECK[@]} -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  line_num=0
  seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    [[ -z "${line// }" ]] || seen=1
    validate_line "$line" "stdin (Zeile $line_num)"
  done

  if [[ $seen -eq 0 ]]; then
    if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
      echo "❌ Keine Daten auf stdin (REQUIRE_NONEMPTY=1)" >&2
      exit 1
    else
      echo "⚠️  Keine Daten auf stdin erhalten." >&2
    fi
  else
    echo "OK: Stdin-Daten sind valide."
  fi
else
  print_usage
  exit 1
fi
