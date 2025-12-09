#!/bin/bash
set -e

SCHEMA_FILE="$1"
FIXTURES_PATTERN="$2"

if [ -z "$SCHEMA_FILE" ] || [ -z "$FIXTURES_PATTERN" ]; then
  echo "Usage: $0 <schema-file> <fixtures-pattern>"
  exit 1
fi

# Find all JSONL files matching the pattern
# Convert glob pattern to find pattern (e.g., tests/fixtures/**/*.jsonl -> tests/fixtures)
SEARCH_DIR=$(echo "$FIXTURES_PATTERN" | sed 's|/\*\*/\*\.jsonl$||')
mapfile -t JSONL_FILES < <(find "$SEARCH_DIR" -name "*.jsonl" -type f)

if [ ${#JSONL_FILES[@]} -eq 0 ]; then
  echo "No JSONL files found matching pattern: $FIXTURES_PATTERN"
  exit 1
fi

TOTAL_LINES=0
VALID_LINES=0
INVALID_LINES=0
TEMP_DIR=$(mktemp -d)

echo "Validating JSONL fixtures against schema: $SCHEMA_FILE"
echo "================================================"

for JSONL_FILE in "${JSONL_FILES[@]}"; do
  echo "Processing: $JSONL_FILE"
  LINE_NUM=0
  
  while IFS= read -r line; do
    LINE_NUM=$((LINE_NUM + 1))
    TOTAL_LINES=$((TOTAL_LINES + 1))
    
    # Skip empty lines
    if [ -z "$line" ]; then
      continue
    fi
    
    # Validate that the line is valid JSON
    if ! echo "$line" | jq empty 2>/dev/null; then
      INVALID_LINES=$((INVALID_LINES + 1))
      echo "  ❌ Line $LINE_NUM is INVALID: Not valid JSON"
      continue
    fi
    
    # Write the line to a temporary JSON file
    TEMP_JSON="$TEMP_DIR/line_${LINE_NUM}.json"
    echo "$line" > "$TEMP_JSON"
    
    # Validate the JSON against the schema
    if npx --yes ajv-cli@5 validate \
      -s "$SCHEMA_FILE" \
      -d "$TEMP_JSON" \
      --spec=draft2020 \
      --errors=line \
      --strict=false \
      > /dev/null 2>&1; then
      VALID_LINES=$((VALID_LINES + 1))
    else
      INVALID_LINES=$((INVALID_LINES + 1))
      echo "  ❌ Line $LINE_NUM is INVALID"
      npx --yes ajv-cli@5 validate \
        -s "$SCHEMA_FILE" \
        -d "$TEMP_JSON" \
        --spec=draft2020 \
        --errors=text \
        --strict=false 2>&1 | grep -E "^(error:|data.*invalid$)" || true
    fi
  done < "$JSONL_FILE"
  
  echo "  Lines processed: $LINE_NUM"
  echo ""
done

# Cleanup
rm -rf "$TEMP_DIR"

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
