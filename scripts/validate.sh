#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"
TMP_EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.validate.XXXXXX.json")"
TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"

# shellcheck disable=SC2317  # cleanup is called via trap
cleanup() {
  rm -f "$TMP_EVENT_FILE" "$TMP_SCHEMA_FILE"
}
trap cleanup EXIT

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
    AJV_CMD=(npx -y -p ajv-cli@5 -p ajv-formats ajv)
    return 0
  fi

  echo "Fehler: 'ajv' wird benötigt, ist aber nicht im PATH." >&2
  echo "Hinweis: Installiere ajv-cli z. B. mit:" >&2
  echo "  npm install -g ajv-cli ajv-formats" >&2
  exit 1
}

setup_ajv
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

validate_file() {
  local file_path="$1"
  local context="$2"

  # Check for non-empty content.
  if [[ ! -s "$file_path" ]]; then
    if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
      echo "❌ Keine Ereignisse zur Validierung in '$context' (REQUIRE_NONEMPTY=1)" >&2
      return 1
    else
      echo "⚠️  Keine Ereignisse zur Validierung in '$context'" >&2
      return 0
    fi
  fi

  # Validate line by line for robust JSONL processing.
  # ajv-cli's file mode doesn't reliably handle JSONL format, so we process each line individually.
  local line_num=0
  local has_errors=0
  local has_content=0
  local tmp_line_file="$(mktemp "${TMPDIR:-/tmp}/aussen_event.line.XXXXXX.json")"
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    
    # Skip empty lines
    if [[ -z "$line" ]]; then
      continue
    fi
    
    has_content=1
    
    # Write line to temp file for validation
    echo "$line" > "$tmp_line_file"
    
    # Validate this single JSON object
    # --strict=false is a conscious policy choice. It relaxes some schema validation rules.
    # For this use case, it is primarily used to allow additional, undocumented properties,
    # which supports schema evolution and backward compatibility.
    if ! "${AJV_CMD[@]}" validate -s "$TMP_SCHEMA_FILE" -d "$tmp_line_file" --spec=draft7 --strict=false -c ajv-formats >/dev/null 2>&1; then
      if [[ $has_errors -eq 0 ]]; then
        echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
        echo "Details:" >&2
        has_errors=1
      fi
      echo "Line $line_num:" >&2
      "${AJV_CMD[@]}" validate -s "$TMP_SCHEMA_FILE" -d "$tmp_line_file" --spec=draft7 --strict=false -c ajv-formats --errors=text 2>&1 | sed 's/^/  /' >&2
    fi
  done < "$file_path"
  
  rm -f "$tmp_line_file"
  
  if [[ $has_content -eq 0 ]]; then
    if [[ "$REQUIRE_NONEMPTY" -eq 1 ]]; then
      echo "❌ Keine Ereignisse zur Validierung in '$context' (REQUIRE_NONEMPTY=1)" >&2
      return 1
    else
      echo "⚠️  Keine Ereignisse zur Validierung in '$context'" >&2
      return 0
    fi
  fi
  
  if [[ $has_errors -eq 1 ]]; then
    return 1
  fi

  echo "OK: '$context' ist valide ($line_num lines)."
  return 0
}

if [[ ${#FILES_TO_CHECK[@]} -gt 0 ]]; then
  status=0
  for FILE_TO_CHECK in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$FILE_TO_CHECK" ]]; then
      echo "Fehlt: $FILE_TO_CHECK" >&2
      status=1
      continue
    fi

    if ! validate_file "$FILE_TO_CHECK" "$FILE_TO_CHECK"; then
      status=1
    fi
  done
  exit $status

elif [[ ${#FILES_TO_CHECK[@]} -eq 0 && ! -t 0 ]]; then
  # Stdin mode: read all of stdin to a temp file first
  cat >"$TMP_EVENT_FILE"

  if ! validate_file "$TMP_EVENT_FILE" "stdin"; then
    exit 1
  fi
  exit 0
else
  print_usage
  exit 1
fi
