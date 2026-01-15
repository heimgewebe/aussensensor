#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"
TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"
TMP_DATA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.data.XXXXXX.json")"
WRAPPER_SCHEMA="$(mktemp "${TMPDIR:-/tmp}/aussen_event.wrapper.XXXXXX.json")"
TMP_STDIN=""

# shellcheck disable=SC2317  # cleanup is called via trap
cleanup() {
  rm -f "$TMP_SCHEMA_FILE" "$TMP_DATA_FILE" "$WRAPPER_SCHEMA"
  if [[ -n "${TMP_STDIN:-}" ]]; then
    rm -f "$TMP_STDIN"
  fi
}
trap cleanup EXIT INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
    exit 1
  }
}

setup_ajv() {
  if command -v ajv >/dev/null 2>&1; then
    AJV_CMD=(ajv)
    return 0
  fi

  if command -v npx >/dev/null 2>&1; then
    # Pin versions for stability and to match draft-07 requirements
    AJV_CMD=(npx -y -p ajv-cli@5 -p ajv-formats@2 ajv)
    return 0
  fi

  echo "Fehler: 'ajv' wird benötigt (weder lokal noch via 'npx' gefunden)." >&2
  exit 1
}

setup_ajv
need sed
need jq

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

# Prepare patched schema for ajv
# ajv-cli (v5) has limited 2020-12 support. We patch $schema to draft-07 on-the-fly
# to allow validation while keeping the source file in sync with metarepo (2020-12).
# Normalize both draft/2020-12 and any existing draft-07 URLs to use http:// (not https://)
# to match AJV's internal meta-schema registration.
sed \
  -e 's|https://json-schema.org/draft/2020-12/schema|http://json-schema.org/draft-07/schema#|g' \
  -e 's|https://json-schema.org/draft-07/schema#|http://json-schema.org/draft-07/schema#|g' \
  "$SCHEMA_FILE" > "$TMP_SCHEMA_FILE"

# Extract Schema ID to use in wrapper
SCHEMA_ID="$(jq -r '."$id" // empty' "$TMP_SCHEMA_FILE")"
if [[ -z "$SCHEMA_ID" ]]; then
  echo "Warnung: Keine \$id im Schema gefunden. Referenzierung könnte fehlschlagen." >&2
  SCHEMA_ID="file://${TMP_SCHEMA_FILE}"
fi

# Create Wrapper Schema (Array of Items)
cat > "$WRAPPER_SCHEMA" <<EOF
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "type": "array",
  "items": { "\$ref": "$SCHEMA_ID" }
}
EOF

validate_file() {
  local input_file="$1"

  # Check if empty (bash check for 0 size)
  if [[ ! -s "$input_file" ]]; then
    return 2 # Empty
  fi

  # Slurp into array; jq fails on invalid JSON lines
  if ! jq -s . "$input_file" > "$TMP_DATA_FILE"; then
    echo "Fehler: Ungültiges JSON in '$input_file'." >&2
    return 1
  fi

  # Treat "only whitespace" as empty data
  local count
  count="$(jq length "$TMP_DATA_FILE")"
  if [[ "$count" -eq 0 ]]; then
    return 2
  fi

  # Validate array against wrapper schema, with patched schema as referenced
  if ! "${AJV_CMD[@]}" validate \
    -s "$WRAPPER_SCHEMA" \
    -r "$TMP_SCHEMA_FILE" \
    -d "$TMP_DATA_FILE" \
    --spec=draft7 --strict=false -c ajv-formats >/dev/null; then

    echo "Fehler: Validierung fehlgeschlagen in '$input_file'." >&2
    echo "Details:" >&2
    "${AJV_CMD[@]}" validate \
      -s "$WRAPPER_SCHEMA" \
      -r "$TMP_SCHEMA_FILE" \
      -d "$TMP_DATA_FILE" \
      --spec=draft7 --strict=false -c ajv-formats --errors=text
    return 1
  fi

  return 0
}

status=0

if [[ ${#FILES_TO_CHECK[@]} -gt 0 ]]; then
  for FILE_TO_CHECK in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$FILE_TO_CHECK" ]]; then
      echo "Fehlt: $FILE_TO_CHECK" >&2
      status=1
      continue
    fi

    set +e
    validate_file "$FILE_TO_CHECK"
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
      echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."
    elif [[ $exit_code -eq 2 ]]; then
      if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
        echo "❌ Keine Ereignisse zur Validierung in '$FILE_TO_CHECK' (REQUIRE_NONEMPTY=1)" >&2
        status=1
      else
        echo "⚠️  Keine Ereignisse zur Validierung in '$FILE_TO_CHECK'" >&2
      fi
    else
      status=1
    fi
  done
  exit "$status"

elif [[ ${#FILES_TO_CHECK[@]} -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus: jq -s braucht ein File
  TMP_STDIN="$(mktemp "${TMPDIR:-/tmp}/aussen_stdin.XXXXXX.json")"
  cat > "$TMP_STDIN"

  set +e
  validate_file "$TMP_STDIN"
  exit_code=$?
  set -e

  if [[ $exit_code -eq 0 ]]; then
    echo "OK: Stdin-Daten sind valide."
  elif [[ $exit_code -eq 2 ]]; then
    if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
      echo "❌ Keine Daten auf stdin (REQUIRE_NONEMPTY=1)" >&2
      exit 1
    else
      echo "⚠️  Keine Daten auf stdin erhalten." >&2
    fi
  else
    exit 1
  fi
  exit 0
else
  print_usage
  exit 1
fi
