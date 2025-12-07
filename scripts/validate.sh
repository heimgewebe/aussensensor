#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"
TMP_EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.validate.XXXXXX.json")"
TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"

cleanup() {
  rm -f "$TMP_EVENT_FILE" "$TMP_SCHEMA_FILE"
}
trap cleanup EXIT INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehlt: $1" >&2
    exit 1
  }
}

need ajv
need sed

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [-s|--schema PATH] [file.jsonl ...]
    Validiert jede Zeile der angegebenen Datei(en).

  <json-producer> | ./scripts/validate.sh [-s|--schema PATH]
    Validiert das JSON-Objekt von stdin.

Umgebungsvariablen:
  REQUIRE_NONEMPTY=1      Fehler bei leeren Dateien oder leerem stdin.

Beispiel:
  ./scripts/validate.sh -s contracts/aussen.event.schema.json export/feed.jsonl
USAGE
}

# --- Main --------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
  -s | --schema)
    if [[ $# -lt 2 ]]; then
      echo "Fehler: --schema benötigt einen Pfad." >&2
      print_usage
      exit 1
    fi
    SCHEMA_FILE="$2"
    shift 2
    ;;
  -h | --help)
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

# Prepare patched schema for ajv
# ajv-cli (v5) has limited 2020-12 support. We patch $schema to draft-07 on-the-fly
# to allow validation while keeping the source file in sync with metarepo (2020-12).
# This works because our schema doesn't use 2020-12-exclusive features.
# If metarepo adds 2020-12-specific features later, consider upgrading to a newer ajv version.
sed 's|https://json-schema.org/draft/2020-12/schema|http://json-schema.org/draft-07/schema#|' "$SCHEMA_FILE" > "$TMP_SCHEMA_FILE"

validate_line() {
  local line="$1"
  local context="${2:-stdin}"

  # Leere Zeilen ignorieren
  [[ -z "${line// /}" ]] && return 0

  # Write line to temp file with trailing newline
  printf '%s\n' "$line" >"$TMP_EVENT_FILE"

  if ! ajv validate -s "$TMP_SCHEMA_FILE" -d "$TMP_EVENT_FILE" --spec=draft7 --strict=false -c ajv-formats >/dev/null; then
          echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
          echo "JSON-Objekt:" >&2
          cat "$TMP_EVENT_FILE" >&2
          echo "Details:" >&2
          ajv validate -s "$TMP_SCHEMA_FILE" -d "$TMP_EVENT_FILE" --spec=draft7 --strict=false -c ajv-formats --errors=text
          return 1
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
      [[ -z "${line// /}" ]] || seen=1
      if ! validate_line "$line" "Zeile $line_num in '$FILE_TO_CHECK'"; then
          status=1
      fi
    done <"$FILE_TO_CHECK"

    if [[ $seen -eq 0 ]]; then
      if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
        echo "❌ Keine Ereignisse zur Validierung in '$FILE_TO_CHECK' (REQUIRE_NONEMPTY=1)" >&2
        status=1
      else
        echo "⚠️  Keine Ereignisse zur Validierung in '$FILE_TO_CHECK'" >&2
      fi
    elif [[ $status -eq 0 ]]; then
      echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."
    fi
  done
  exit $status

elif [[ ${#FILES_TO_CHECK[@]} -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  line_num=0
  seen=0
  status=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    [[ -z "${line// /}" ]] || seen=1
    if ! validate_line "$line" "stdin (Zeile $line_num)"; then
        status=1
    fi
  done

  if [[ $seen -eq 0 ]]; then
    if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
      echo "❌ Keine Daten auf stdin (REQUIRE_NONEMPTY=1)" >&2
      exit 1
    else
      echo "⚠️  Keine Daten auf stdin erhalten." >&2
    fi
  elif [[ $status -eq 0 ]]; then
    echo "OK: Stdin-Daten sind valide."
  fi
  exit $status
else
  print_usage
  exit 1
fi
