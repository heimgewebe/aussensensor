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
TMP_EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.validate.XXXXXX.json")"

# shellcheck disable=SC2317  # cleanup is called via trap
cleanup() {
  rm -f "$TMP_SCHEMA_FILE" "$TMP_EVENT_FILE"
}
trap cleanup EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
    exit 1
  }
}

setup_ajv() {
  # Prioritize local node_modules for deterministic validation
  if [[ -x "$REPO_ROOT/node_modules/.bin/ajv" ]]; then
    AJV_CMD=("$REPO_ROOT/node_modules/.bin/ajv")
    return 0
  fi

  # Use npx with pinned versions as fallback
  if command -v npx >/dev/null 2>&1; then
    AJV_CMD=(npx -y -p ajv-cli@5.0.0 -p ajv-formats@2.1.1 ajv)
    return 0
  fi

  # Global ajv as last resort
  if command -v ajv >/dev/null 2>&1; then
    AJV_CMD=(ajv)
    return 0
  fi

  echo "Fehler: 'ajv' wird benötigt, ist aber nicht im PATH." >&2
  echo "Hinweis: Installiere ajv-cli z. B. mit:" >&2
  echo "  npm install -g ajv-cli ajv-formats" >&2
  exit 1
}

setup_ajv
need sed

# Prepare patched schema for ajv
# ajv-cli (v5) has limited 2020-12 support. We patch $schema to draft-07 on-the-fly
# to allow validation while keeping the source file in sync with metarepo (2020-12).
# This works because our schema doesn't use 2020-12-exclusive features.
# If metarepo adds 2020-12-specific features later, consider upgrading to a newer ajv version.
# Normalize both draft/2020-12 and any existing draft-07 URLs to use http:// (not https://)
# to match AJV's internal meta-schema registration.
sed \
  -e 's|https://json-schema.org/draft/2020-12/schema|http://json-schema.org/draft-07/schema#|g' \
  -e 's|https://json-schema.org/draft-07/schema#|http://json-schema.org/draft-07/schema#|g' \
  "$SCHEMA_FILE" > "$TMP_SCHEMA_FILE"

# Find all JSONL files in the directory
mapfile -t JSONL_FILES < <(find "$SEARCH_DIR" -name "*.jsonl" -type f)

if [ ${#JSONL_FILES[@]} -eq 0 ]; then
  echo "No JSONL files found in: $SEARCH_DIR"
  exit 1
fi

errors_found=0
total_lines=0
invalid_lines=0

echo "Validating JSONL fixtures in '$SEARCH_DIR' against schema: $SCHEMA_FILE"
echo "================================================"

for JSONL_FILE in "${JSONL_FILES[@]}"; do
  echo "Processing: $JSONL_FILE"

  # Skip empty files
  if [[ ! -s "$JSONL_FILE" ]]; then
    echo "  ⚠️ Skipping empty file."
    continue
  fi

  # Process line by line for robust validation
  line_num=0
  file_has_errors=0
  validated_lines=0
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    
    # Skip empty lines and whitespace-only lines
    if [[ -z "${line//[[:space:]]/}" ]]; then
      continue
    fi
    
    validated_lines=$((validated_lines + 1))
    total_lines=$((total_lines + 1))
    
    # Write line to temp file for validation (byte-safe)
    printf '%s\n' "$line" > "$TMP_EVENT_FILE"
    
    # Validate this single JSON object
    # --strict=false is a conscious policy choice. It relaxes some schema validation rules.
    # For this use case, it is primarily used to allow additional, undocumented properties,
    # which supports schema evolution and backward compatibility.
    if ! validation_output=$("${AJV_CMD[@]}" validate -s "$TMP_SCHEMA_FILE" -d "$TMP_EVENT_FILE" --spec=draft7 --strict=false -c ajv-formats --errors=text 2>&1); then
      if [[ $file_has_errors -eq 0 ]]; then
        echo "  ❌ INVALID"
        file_has_errors=1
        errors_found=$((errors_found + 1))
      fi
      echo "    Line $line_num: Validation failed"
      # Show detailed error for this line, indented
      while IFS= read -r l; do
        printf '      %s\n' "$l"
      done <<<"$validation_output"
      invalid_lines=$((invalid_lines + 1))
    fi
  done < "$JSONL_FILE"
  
  if [[ $file_has_errors -eq 0 ]]; then
    echo "  ✅ OK ($validated_lines lines validated)"
  fi
done

echo "================================================"

if [ $errors_found -gt 0 ]; then
  echo "❌ Validation FAILED: $errors_found file(s) failed validation ($invalid_lines invalid lines out of $total_lines total)."
  exit 1
else
  echo "✅ All fixtures are valid! ($total_lines lines checked)"
  exit 0
fi
