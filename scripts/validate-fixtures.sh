#!/bin/bash
set -e

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

# Find all JSONL files in the directory
mapfile -t JSONL_FILES < <(find "$SEARCH_DIR" -name "*.jsonl" -type f)

if [ ${#JSONL_FILES[@]} -eq 0 ]; then
  echo "No JSONL files found in: $SEARCH_DIR"
  exit 1
fi

TOTAL_LINES=0
VALID_LINES=0
INVALID_LINES=0
TEMP_DIR=$(mktemp -d)

# Setup cleanup trap
# shellcheck disable=SC2317
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "Validating JSONL fixtures in '$SEARCH_DIR' against schema: $SCHEMA_FILE"
echo "================================================"

# Determine validator command
if ! command -v ajv >/dev/null 2>&1; then
  echo "Error: 'ajv' is required but not found in PATH."
  echo "Please install it, e.g., with: npm install -g ajv-cli@5.0.0 ajv-formats"
  exit 1
fi
CMD=(ajv)

for JSONL_FILE in "${JSONL_FILES[@]}"; do
  echo "Processing: $JSONL_FILE"
  LINE_NUM=0
  
  while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    
    # Skip empty lines
    if [ -z "${line// /}" ]; then
      continue
    fi
    TOTAL_LINES=$((TOTAL_LINES + 1))
    
    # Validate that the line is valid JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
      INVALID_LINES=$((INVALID_LINES + 1))
      echo "  ❌ Line $LINE_NUM is INVALID: Not valid JSON"
      continue
    fi
    
    # Write the line to a temporary JSON file
    TEMP_JSON="$TEMP_DIR/line_${LINE_NUM}.json"
    printf '%s\n' "$line" > "$TEMP_JSON"
    
    # Validate the JSON against the schema
    if "${CMD[@]}" validate \
      -s "$SCHEMA_FILE" \
      -d "$TEMP_JSON" \
      --spec=draft2020 \
      --errors=line \
      --strict=false \
      -c ajv-formats \
      > /dev/null 2>&1; then
      VALID_LINES=$((VALID_LINES + 1))
    else
      INVALID_LINES=$((INVALID_LINES + 1))
      echo "  ❌ Line $LINE_NUM in $JSONL_FILE is INVALID"
      "${CMD[@]}" validate \
        -s "$SCHEMA_FILE" \
        -d "$TEMP_JSON" \
        --spec=draft2020 \
        --errors=text \
        --strict=false \
        -c ajv-formats 2>&1 | grep -E "^(error:|data.*invalid$)" || true
    fi
  done < "$JSONL_FILE"
  
  echo "  Lines processed: $LINE_NUM"
  echo ""
done

echo "================================================"
echo "Summary:"
echo "  Total lines validated: $TOTAL_LINES"
echo "  Valid: $VALID_LINES"
echo "  Invalid: $INVALID_LINES"
echo "================================================"

if [ $INVALID_LINES -gt 0 ]; then
  echo "❌ Validation FAILED: $INVALID_LINES invalid line(s) found"
  exit 1
else
  echo "✅ All fixtures are valid!"
  exit 0
fi
