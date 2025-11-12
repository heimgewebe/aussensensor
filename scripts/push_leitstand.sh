#!/usr/bin/env bash
# MVP vs. Zielpfad
# - Zielpfad (bevorzugt): ingest NUR via leitstand (/v1/ingest)
# - Dieses Skript ist bereits auf das Ziel ausgelegt und fällt bei Bedarf auf curl zurück.
set -euo pipefail

print_usage() {
  cat <<'USAGE' >&2
Usage: scripts/push_leitstand.sh [options]

Options:
  -f, --file PATH        Pfad zur JSONL-Datei (Standard: export/feed.jsonl)
      --url URL          Ziel-Endpoint (überschreibt $LEITSTAND_INGEST_URL)
      --token TOKEN      Authentifizierungs-Token (überschreibt $LEITSTAND_TOKEN)
      --content-type CT  Content-Type (Standard: application/x-ndjson)
      --dry-run          Keine Übertragung, nur Anzeige der Aktion
  -h, --help             Hilfe anzeigen
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE_PATH="$REPO_ROOT/export/feed.jsonl"
INGEST_URL="${LEITSTAND_INGEST_URL:-}"
AUTH_TOKEN="${LEITSTAND_TOKEN:-}"
CONTENT_TYPE="${CONTENT_TYPE:-application/x-ndjson}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  -f | --file)
    [[ $# -ge 2 ]] || {
      echo "Fehlender Parameter für $1" >&2
      exit 1
    }
    FILE_PATH="$2"
    shift 2
    ;;
  --url)
    [[ $# -ge 2 ]] || {
      echo "Fehlender Parameter für --url" >&2
      exit 1
    }
    INGEST_URL="$2"
    shift 2
    ;;
  --token)
    [[ $# -ge 2 ]] || {
      echo "Fehlender Parameter für --token" >&2
      exit 1
    }
    AUTH_TOKEN="$2"
    shift 2
    ;;
  --content-type)
    [[ $# -ge 2 ]] || {
      echo "Fehlender Parameter für --content-type" >&2
      exit 1
    }
    CONTENT_TYPE="$2"
    shift 2
    ;;
  --dry-run)
    DRY_RUN=1
    shift
    ;;
  -h | --help)
    print_usage
    exit 0
    ;;
  *)
    echo "Unbekannte Option: $1" >&2
    print_usage
    exit 1
    ;;
  esac
done

[[ -n "$INGEST_URL" ]] || {
  echo "Fehler: LEITSTAND_INGEST_URL fehlt und --url wurde nicht übergeben." >&2
  exit 1
}
[[ -f "$FILE_PATH" ]] || {
  echo "Fehler: Datei '$FILE_PATH' nicht gefunden." >&2
  exit 1
}
if command -v aussensensor-push >/dev/null 2>&1; then
  echo "→ Push via aussensensor-push (NDJSON) → $INGEST_URL"
  AUSSENSENSOR_ARGS=("--url" "$INGEST_URL" "--file" "$FILE_PATH")
  if [[ -n "$AUTH_TOKEN" ]]; then
    AUSSENSENSOR_ARGS+=("--token" "$AUTH_TOKEN")
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    AUSSENSENSOR_ARGS+=("--dry-run")
  fi
  aussensensor-push "${AUSSENSENSOR_ARGS[@]}"
else
  command -v curl >/dev/null 2>&1 || {
    echo "Fehlt: curl" >&2
    exit 1
  }
  echo "→ Push via curl (Fallback) → $INGEST_URL"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Würde $(grep -c . "$FILE_PATH") Ereignis(se) an '$INGEST_URL' übertragen." >&2
    echo "[DRY-RUN] Datei: $FILE_PATH" >&2
    echo "[DRY-RUN] Content-Type: $CONTENT_TYPE" >&2
    if [[ -n "$AUTH_TOKEN" ]]; then
      echo "[DRY-RUN] Token: gesetzt (${#AUTH_TOKEN} Zeichen)." >&2
    else
      echo "[DRY-RUN] Token: nicht gesetzt." >&2
    fi
    head -n5 "$FILE_PATH" >&2 || true
    exit 0
  fi
  CURL_ARGS=("-fsS" "-H" "content-type: $CONTENT_TYPE" "--data-binary" "@$FILE_PATH")
  if [[ -n "$AUTH_TOKEN" ]]; then
    CURL_ARGS+=("-H" "x-auth: $AUTH_TOKEN")
  fi
  curl "${CURL_ARGS[@]}" "$INGEST_URL"
  echo
fi
