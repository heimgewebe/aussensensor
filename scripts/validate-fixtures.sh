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

errors_found=0

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

  # Skip empty files
  if [[ ! -s "$JSONL_FILE" ]]; then
    echo "  ⚠️ Skipping empty file."
    continue
  fi

  # Validate the entire JSONL file at once
  # --strict=false is a conscious policy choice. It allows events to contain additional,
  # undocumented properties. This supports schema evolution and backward compatibility.
  if "${CMD[@]}" validate \
    -s "$SCHEMA_FILE" \
    -d "$JSONL_FILE" \
    --spec=draft2020 \
    --errors=text \
    --strict=false \
    -c ajv-formats; then
    echo "  ✅ OK"
  else
    errors_found=$((errors_found + 1))
    echo "  ❌ INVALID"
  fi
done

echo "================================================"

if [ $errors_found -gt 0 ]; then
  echo "❌ Validation FAILED: $errors_found file(s) with invalid lines found"
  exit 1
else
  echo "✅ All fixtures are valid!"
  exit 0
fi
