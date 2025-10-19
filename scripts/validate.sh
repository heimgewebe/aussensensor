#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [file.jsonl]
    Validiert jede Zeile der angegebenen Datei.

  <json-producer> | ./scripts/validate.sh
    Validiert das JSON-Objekt von stdin.
USAGE
}

# --- Main --------------------------------------------------------------------

need npx

# Temporäre Datei für die Validierung erstellen und Bereinigung sicherstellen
TMP_EVENT_FILE="$(mktemp /tmp/aussen_event.XXXX.json)"
trap 'rm -f "$TMP_EVENT_FILE"' EXIT

validate_line() {
  local line="$1"
  local context="$2"

  # Leere Zeilen ignorieren
  [[ -z "${line// }" ]] && return 0

  printf '%s\n' "$line" > "$TMP_EVENT_FILE"

  if ! npx -y ajv-cli@5 validate \
    --spec=draft2020 \
    --strict=false \
    --validate-formats=false \
    -s "$SCHEMA_PATH" \
    -d "$TMP_EVENT_FILE" >/dev/null; then
    echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
    # Zeige die ausführliche Fehlermeldung von ajv
    npx -y ajv-cli@5 validate \
      --spec=draft2020 \
      --strict=false \
      --validate-formats=false \
      -s "$SCHEMA_PATH" \
      -d "$TMP_EVENT_FILE"
    exit 1
  fi
}

if [[ $# -gt 0 && -f "$1" ]]; then
  # Datei-Modus
  FILE_TO_CHECK="$1"
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "Zeile $line_num in '$FILE_TO_CHECK'"
  done < "$FILE_TO_CHECK"
  echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."

elif [[ $# -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "stdin (Zeile $line_num)"
  done
  echo "OK: Stdin-Daten sind valide."
else
  print_usage
  exit 1
fi
