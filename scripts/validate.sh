#!/usr/bin/env bash
set -euo pipefail

FILE="${1:-export/feed.jsonl}"
SCHEMA="${2:-contracts/aussen.event.schema.json}"
STRICT="${STRICT:-false}"
VALIDATE_FORMATS="${VALIDATE_FORMATS:-false}"

if [[ ! -f "$FILE" ]]; then
  echo "missing $FILE" >&2
  exit 1
fi

if [[ ! -f "$SCHEMA" ]]; then
  echo "missing $SCHEMA" >&2
  exit 1
fi

tmp_json="$(mktemp "${TMPDIR:-/tmp}/aussen_event.XXXXXX.json")"
cleanup() {
  rm -f "$tmp_json"
}
trap cleanup EXIT

count_total=0
count_valid=0
lineno=0
status=0

while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno+1))
  [[ -z "${line// }" ]] && continue
  count_total=$((count_total+1))
  printf '%s' "$line" > "$tmp_json"
  if ! npx -y ajv-cli@5 validate \
        --spec=draft2020 \
        --strict="${STRICT}" \
        --validate-formats="${VALIDATE_FORMATS}" \
        -s "$SCHEMA" \
        -d "$tmp_json"; then
    echo "❌ Validation failed at line ${lineno} of ${FILE}" >&2
    echo "---- offending line ----" >&2
    printf '%s\n' "$line" >&2
    echo "------------------------" >&2
    status=1
    break
  fi
  count_valid=$((count_valid+1))
done <"$FILE"

if [[ $count_total -eq 0 ]]; then
  echo "⚠️  No events to validate in ${FILE}" >&2
fi

exit $status
