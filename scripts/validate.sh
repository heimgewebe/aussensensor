#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
REQUIRE_NONEMPTY="${REQUIRE_NONEMPTY:-0}"
SCHEMA_FILE="${SCHEMA_FILE:-$SCHEMA_PATH}"

TMP_SCHEMA_FILE="$(mktemp "${TMPDIR:-/tmp}/aussen_event.schema.XXXXXX.json")"
TMP_STDIN=""

cleanup() {
  rm -f "$TMP_SCHEMA_FILE"
  if [[ -n "${TMP_STDIN:-}" ]]; then
    rm -f "$TMP_STDIN"
  fi
}
trap cleanup EXIT INT TERM

# shellcheck source=scripts/utils.sh
if [[ -f "$SCRIPT_DIR/utils.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/utils.sh"
else
  # Fallback: keep script standalone if copied without utils.sh
  have() { command -v "$1" >/dev/null 2>&1; }
  need() {
    if ! have "$1"; then
      echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
      exit 1
    fi
  }
fi

check_deps() {
  need node
  # Ensure we check for modules in the repo root so require() finds them
  if ! (cd "$REPO_ROOT" && node -e "try { require('ajv'); require('ajv-formats'); } catch(e) { process.exit(1); }") 2>/dev/null; then
    echo "Fehler: 'ajv' und 'ajv-formats' werden benötigt. Bitte '(cd $REPO_ROOT && npm ci)' ausführen." >&2
    exit 1
  fi
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [-s|--schema PATH] [file.jsonl ...]
    Validiert JSONL-Datei(en) im Streaming-Verfahren gegen ein Schema.

  <jsonl-producer> | ./scripts/validate.sh [-s|--schema PATH]
    Validiert JSONL von stdin.

Umgebungsvariablen:
  REQUIRE_NONEMPTY=1      Fehler bei leeren Dateien oder leerem stdin.

Beispiel:
  ./scripts/validate.sh -s contracts/aussen.event.schema.json tests/fixtures/aussen/demo.jsonl
USAGE
}

check_deps
need sed

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


# --- Validation ---------------------------------------------------------------

validate_file() {
  local input_file="$1"

  # Empty file (0 bytes) => "no data"
  if [[ ! -s "$input_file" ]]; then
    return 2
  fi

  # Stream validation using Node.js script
  # We do NOT cd to REPO_ROOT here, so that relative paths in $input_file work correctly.
  # The Node script (in SCRIPT_DIR) will find its dependencies via Node's module resolution
  # (looking in SCRIPT_DIR/node_modules, then SCRIPT_DIR/../node_modules).

  # Pass original schema directory as second argument to support relative $refs resolution
  node "$SCRIPT_DIR/validate_stream.js" "$TMP_SCHEMA_FILE" "$(dirname "$SCHEMA_FILE")" < "$input_file"
  local ret=$?

  if [[ $ret -eq 0 ]]; then
    return 0
  elif [[ $ret -eq 2 ]]; then
    return 2
  else
    return 1
  fi
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
