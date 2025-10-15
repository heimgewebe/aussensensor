#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: scripts/push_leitstand.sh [options]

Options:
  -f, --file PATH      Pfad zur JSONL-Datei (Standard: export/feed.jsonl)
      --url URL        Ziel-Endpoint (überschreibt $LEITSTAND_INGEST_URL)
      --token TOKEN    Authentifizierungs-Token (überschreibt $LEITSTAND_TOKEN)
      --dry-run        Keine Übertragung, sondern nur Anzeige der Aktion
  -h, --help           Diese Hilfe anzeigen
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE_PATH="$REPO_ROOT/export/feed.jsonl"
INGEST_URL="${LEITSTAND_INGEST_URL:-}"
AUTH_TOKEN="${LEITSTAND_TOKEN:-}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für $1" >&2; exit 1; }
      FILE_PATH="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --url" >&2; exit 1; }
      INGEST_URL="$2"
      shift 2
      ;;
    --token)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --token" >&2; exit 1; }
      AUTH_TOKEN="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INGEST_URL" ]]; then
  echo "Fehler: LEITSTAND_INGEST_URL ist nicht gesetzt und --url wurde nicht übergeben." >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "Fehler: Datei '$FILE_PATH' nicht gefunden." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Fehlt: curl" >&2
  exit 1
fi

event_count=0
if [[ -f "$FILE_PATH" ]]; then
  event_count="$(grep -cve '^\s*$' "$FILE_PATH" 2>/dev/null || echo 0)"
fi

if [[ ! -s "$FILE_PATH" ]]; then
  echo "Warnung: Datei '$FILE_PATH' ist leer." >&2
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] Würde $event_count Ereignis(se) an '$INGEST_URL' übertragen." >&2
  echo "[DRY-RUN] Datei: $FILE_PATH" >&2
  if [[ -n "$AUTH_TOKEN" ]]; then
    echo "[DRY-RUN] Token: gesetzt (${#AUTH_TOKEN} Zeichen)." >&2
  else
    echo "[DRY-RUN] Token: nicht gesetzt." >&2
  fi
  if [[ -f "$FILE_PATH" ]]; then
    head -n5 "$FILE_PATH" >&2 || true
  fi
  exit 0
fi

curl_args=(
  --fail
  --silent
  --show-error
  --request POST
  --header "Content-Type: application/x-ndjson"
  --data-binary "@$FILE_PATH"
)

if [[ -n "$AUTH_TOKEN" ]]; then
  curl_args+=(--header "x-auth: $AUTH_TOKEN")
fi

curl "${curl_args[@]}" "$INGEST_URL"
printf '\nOK: Feed an %s gesendet.\n' "$INGEST_URL" >&2
