#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_FILE="$1"
SEARCH_DIR="$2"

if [ -z "$SCHEMA_FILE" ] || [ -z "$SEARCH_DIR" ]; then
  echo "Usage: $0 <schema-file> <directory>"
  echo "Example: $0 contracts/aussen.event.schema.json tests/fixtures/aussen"
  exit 1
fi

if [ ! -d "$SEARCH_DIR" ]; then
  echo "Error: Directory '$SEARCH_DIR' not found."
  exit 1
fi

if [ ! -f "$SCHEMA_FILE" ]; then
  echo "Error: Schema file '$SCHEMA_FILE' not found."
  exit 1
fi

# Create temporary files for processing
TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"
TMP_DATA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.data.XXXXXX.json")"
WRAPPER_SCHEMA="$(mktemp "${TMPDIR:-/tmp}/aussen_event.wrapper.XXXXXX.json")"

cleanup() {
  rm -f "$TMP_SCHEMA_FILE" "$TMP_DATA_FILE" "$WRAPPER_SCHEMA"
}
trap cleanup EXIT INT TERM

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
    exit 1
  }
}

setup_ajv() {
  # 1) Repo-lokales node_modules (deterministisch)
  if [[ -x "$REPO_ROOT/node_modules/.bin/ajv" ]]; then
    AJV_CMD=("$REPO_ROOT/node_modules/.bin/ajv")
    return 0
  fi

  # 2) npx mit gepinnten Versionen
  if command -v npx >/dev/null 2>&1; then
    AJV_CMD=(npx -y -p ajv-cli@5.0.0 -p ajv-formats@2.1.1 ajv)
    return 0
  fi

  # 3) global ajv als letzter Ausweg
  if command -v ajv >/dev/null 2>&1; then
    AJV_CMD=(ajv)
    return 0
  fi

  echo "Fehler: 'ajv' wird benötigt (weder repo-lokal, noch via npx, noch global gefunden)." >&2
  exit 1
}

setup_ajv
need sed
need jq

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

# Find all JSONL files in the directory
mapfile -t JSONL_FILES < <(find "$SEARCH_DIR" -name "*.jsonl" -type f)

if [ ${#JSONL_FILES[@]} -eq 0 ]; then
  echo "No JSONL files found in: $SEARCH_DIR"
  exit 1
fi

echo "Validating JSONL fixtures in '$SEARCH_DIR' against schema: $SCHEMA_FILE"
echo "================================================"

TOTAL_LINES=0
VALID_LINES=0
INVALID_FILES=0

for JSONL_FILE in "${JSONL_FILES[@]}"; do
  echo "Processing: $JSONL_FILE"
  
  # Check if file is empty
  if [[ ! -s "$JSONL_FILE" ]]; then
    echo "  ⚠️  File is empty, skipping"
    continue
  fi
  
  # Slurp JSONL lines into array. jq fails if any non-JSON line exists.
  if ! jq -s . "$JSONL_FILE" > "$TMP_DATA_FILE" 2>/dev/null; then
    echo "  ❌ File contains invalid JSON"
    INVALID_FILES=$((INVALID_FILES + 1))
    continue
  fi
  
  # Count lines in this file
  local_count="$(jq length "$TMP_DATA_FILE")"
  TOTAL_LINES=$((TOTAL_LINES + local_count))
  
  if [[ "$local_count" -eq 0 ]]; then
    echo "  ⚠️  No data in file (only empty lines), skipping"
    continue
  fi
  
  # Validate array using wrapper schema; provide patched schema as referenced resource (-r)
  if "${AJV_CMD[@]}" validate \
      -s "$WRAPPER_SCHEMA" \
      -r "$TMP_SCHEMA_FILE" \
      -d "$TMP_DATA_FILE" \
      --spec=draft7 --strict=false -c ajv-formats >/dev/null 2>&1; then
    VALID_LINES=$((VALID_LINES + local_count))
    echo "  ✅ All $local_count events valid"
  else
    INVALID_FILES=$((INVALID_FILES + 1))
    echo "  ❌ Validation FAILED for this file"
    echo "  Details:" >&2
    "${AJV_CMD[@]}" validate \
      -s "$WRAPPER_SCHEMA" \
      -r "$TMP_SCHEMA_FILE" \
      -d "$TMP_DATA_FILE" \
      --spec=draft7 --strict=false -c ajv-formats --errors=text 2>&1 | head -20
  fi
  
  echo ""
done

echo "================================================"
echo "Summary:"
echo "  Total events validated: $TOTAL_LINES"
echo "  Valid events: $VALID_LINES"
echo "  Files with errors: $INVALID_FILES"
echo "================================================"

if [ $INVALID_FILES -gt 0 ]; then
  echo "❌ Validation FAILED: $INVALID_FILES file(s) with errors"
  exit 1
else
  echo "✅ All fixtures are valid!"
  exit 0
fi
