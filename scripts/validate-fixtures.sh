#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_FILE="${1:-}"
SEARCH_DIR="${2:-}"

if [[ -z "$SCHEMA_FILE" || -z "$SEARCH_DIR" ]]; then
  echo "Usage: $0 <schema-file> <directory>"
  echo "Example: $0 contracts/aussen.event.schema.json tests/fixtures/aussen"
  exit 1
fi

if [[ ! -d "$SEARCH_DIR" ]]; then
  echo "Error: Directory '$SEARCH_DIR' not found."
  exit 1
fi

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Error: Schema file '$SCHEMA_FILE' not found."
  exit 1
fi

VALIDATOR_SCRIPT="$SCRIPT_DIR/validate.sh"

# Optional: ensure validator exists (helps avoid confusing errors)
if [[ ! -f "$VALIDATOR_SCRIPT" ]]; then
  echo "Error: Validator script '$VALIDATOR_SCRIPT' not found."
  exit 1
fi

# Find all JSONL files in the directory
mapfile -t JSONL_FILES < <(find "$SEARCH_DIR" -name "*.jsonl" -type f)

if [[ ${#JSONL_FILES[@]} -eq 0 ]]; then
  echo "No JSONL files found in: $SEARCH_DIR"
  exit 1
fi

echo "Validating JSONL fixtures in '$SEARCH_DIR' against schema: $SCHEMA_FILE"
echo "================================================"

FAILED_FILES=0

for JSONL_FILE in "${JSONL_FILES[@]}"; do
  echo "Processing: $JSONL_FILE"

  # Delegate to canonical validator (single source of truth)
  if bash "$VALIDATOR_SCRIPT" -s "$SCHEMA_FILE" "$JSONL_FILE"; then
    echo "  ✅ Valid"
  else
    echo "  ❌ Invalid"
    FAILED_FILES=$((FAILED_FILES + 1))
  fi

  echo ""
done

echo "================================================"
echo "Summary:"
echo "  Files processed: ${#JSONL_FILES[@]}"
echo "  Failed: $FAILED_FILES"
echo "================================================"

if [[ $FAILED_FILES -gt 0 ]]; then
  echo "❌ Validation FAILED: $FAILED_FILES file(s) failed validation"
  exit 1
fi

echo "✅ All fixtures are valid!"
exit 0
