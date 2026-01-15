#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"
TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"

declare -a CLEANUP_DIRS=()

# shellcheck disable=SC2317  # cleanup is called via trap
cleanup() {
  rm -f "$TMP_SCHEMA_FILE"
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
    exit 1
  }
}

setup_node_validator() {
  local validator_script="$SCRIPT_DIR/validate_stream.js"

  # Check if we can run node
  if ! command -v node >/dev/null 2>&1; then
      echo "Fehler: 'node' wird benötigt." >&2
      exit 1
  fi

  # Check if ajv is available in current environment (e.g. node_modules in repo)
  # We test this by trying to require 'ajv' in a small script
  if node -e "require('ajv')" >/dev/null 2>&1; then
     NODE_VALIDATOR_CMD=(node "$validator_script")
     return 0
  fi

  # If not found, install to temp dir
  if ! command -v npm >/dev/null 2>&1; then
      echo "Fehler: 'npm' wird benötigt, um Abhängigkeiten zu installieren (da 'ajv' nicht gefunden wurde)." >&2
      exit 1
  fi

  local env_dir
  env_dir="$(mktemp -d "${TMPDIR:-/tmp}/ajv_env.XXXXXX")"
  CLEANUP_DIRS+=("$env_dir")

  # Install dependencies (quietly)
  # echo "Initialisiere Validierungsumgebung..." >&2
  if ! npm install --prefix "$env_dir" ajv ajv-formats --no-save --loglevel=error >/dev/null 2>&1; then
      echo "Fehler beim Installieren von Abhängigkeiten." >&2
      exit 1
  fi

  export NODE_PATH="${env_dir}/node_modules:${NODE_PATH:-}"
  NODE_VALIDATOR_CMD=(node "$validator_script")
}

setup_node_validator
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

if [[ ${#FILES_TO_CHECK[@]} -gt 0 ]]; then
  status=0
  for FILE_TO_CHECK in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$FILE_TO_CHECK" ]]; then
      echo "Fehlt: $FILE_TO_CHECK" >&2
      status=1
      continue
    fi

    # Run validation via node stream script
    # Capture exit code: 0=success, 1=invalid, 2=no data
    set +e
    "${NODE_VALIDATOR_CMD[@]}" "$TMP_SCHEMA_FILE" "$FILE_TO_CHECK" < "$FILE_TO_CHECK"
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
      # Exit code 1 or others mean validation failed (errors printed to stderr)
      status=1
    fi
  done
  exit $status

elif [[ ${#FILES_TO_CHECK[@]} -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  set +e
  "${NODE_VALIDATOR_CMD[@]}" "$TMP_SCHEMA_FILE" "stdin"
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
