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
  # 1) Repository-lokales node_modules (deterministisch)
  if [[ -x "$REPO_ROOT/node_modules/.bin/ajv" ]]; then
    AJV_CMD=("$REPO_ROOT/node_modules/.bin/ajv")
    return 0
  fi

  # 2) npx mit gepinnten Versionen (Fallback ohne lokale node_modules)
  if command -v npx >/dev/null 2>&1; then
    AJV_CMD=(npx -y -p ajv-cli@5.0.0 -p ajv-formats@2.1.1 ajv)
    return 0
  fi

  # 3) Globales ajv als letzter Ausweg
  if command -v ajv >/dev/null 2>&1; then
    AJV_CMD=(ajv)
    return 0
  fi

  echo "Fehler: 'ajv' wird benötigt (weder repository-lokal, noch via npx, noch global gefunden)." >&2
  exit 1
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [-s|--schema PATH] [file.jsonl ...]
    Validiert JSONL-Datei(en), indem alle JSON-Zeilen via `jq -s` zu einem Array
    zusammengeführt und als Ganzes gegen ein Wrapper-Schema geprüft werden.

  <jsonl-producer> | ./scripts/validate.sh [-s|--schema PATH]
    Validiert JSONL von stdin (ebenfalls via Array-Zusammenführung).

Umgebungsvariablen:
  REQUIRE_NONEMPTY=1      Fehler bei leeren Dateien oder leerem stdin.

Beispiel:
  ./scripts/validate.sh -s contracts/aussen.event.schema.json tests/fixtures/aussen/demo.jsonl
USAGE
}

setup_ajv
need sed
need jq

# --- Args --------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--schema)
      [[ $# -ge 2 ]] || { echo "Fehler: --schema benötigt einen Pfad." >&2; print_usage; exit 1; }
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

# --- Schema patching ----------------------------------------------------------
# ajv-cli@5 hat begrenzte 2020-12 Unterstützung. Wir patchen $schema on-the-fly auf Draft-07.
# Zusätzlich normalisieren wir Draft-07 meta-schema URLs auf http:// (nicht https://),
# weil ajv-cli@5 das Meta-Schema typischerweise unter http:// registriert.
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

# Wrapper Schema: Array of items referencing patched schema
cat > "$WRAPPER_SCHEMA" <<EOF
{
  "\$schema": "http://json-schema.org/draft-07/schema#",
  "type": "array",
  "items": { "\$ref": "$SCHEMA_ID" }
}
EOF

# --- Validation ---------------------------------------------------------------

validate_file() {
  local input_file="$1"

  # Empty file (0 bytes) => "no data"
  if [[ ! -s "$input_file" ]]; then
    return 2
  fi

  # Slurp JSONL lines into array. jq fails if any non-JSON line exists.
  if ! jq -s . "$input_file" > "$TMP_DATA_FILE"; then
    echo "Fehler: Ungültiges JSON in '$input_file'." >&2
    return 1
  fi

  # File may contain only whitespace/empty lines => array length 0
  local count
  count="$(jq length "$TMP_DATA_FILE")"
  if [[ "$count" -eq 0 ]]; then
    return 2
  fi

  # Validate array using wrapper schema; provide patched schema as referenced resource (-r)
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
  for f in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "Fehlt: $f" >&2
      status=1
      continue
    fi

    set +e
    validate_file "$f"
    exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
      echo "OK: '$f' ist valide."
    elif [[ $exit_code -eq 2 ]]; then
      if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
        echo "❌ Keine Ereignisse zur Validierung in '$f' (REQUIRE_NONEMPTY=1)" >&2
        status=1
      else
        echo "⚠️  Keine Ereignisse zur Validierung in '$f'" >&2
      fi
    else
      status=1
    fi
  done
  exit "$status"
fi

# stdin mode
if [[ -t 0 ]]; then
  print_usage
  exit 1
fi

TMP_STDIN="$(mktemp "${TMPDIR:-/tmp}/aussen_stdin.XXXXXX.jsonl")"
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
    exit 0
  fi
else
  exit 1
fi
