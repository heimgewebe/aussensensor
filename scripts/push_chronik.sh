#!/usr/bin/env bash
# PREFERRED PATH:
# Standard-Ingest erfolgt via chronik (/v1/ingest).
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Fehlt: $1" >&2
    exit 1
  fi
}

print_usage() {
  cat <<'USAGE' >&2
Usage: scripts/push_chronik.sh [options]

Options:
  -f, --file PATH        Pfad zur JSONL-Datei (Standard: export/feed.jsonl)
      --url URL          Ziel-Endpoint (überschreibt $CHRONIK_INGEST_URL)
      --content-type CT  Content-Type (Standard: application/x-ndjson)
      --dry-run          Keine Übertragung, nur Anzeige der Aktion
  -h, --help             Hilfe anzeigen
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE_PATH="$REPO_ROOT/export/feed.jsonl"
INGEST_URL="${CHRONIK_INGEST_URL:-}"
AUTH_TOKEN="${CHRONIK_TOKEN:-}"
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
  echo "Fehler: CHRONIK_INGEST_URL fehlt und --url wurde nicht übergeben." >&2
  exit 1
}
[[ -f "$FILE_PATH" ]] || {
  echo "Fehler: Datei '$FILE_PATH' nicht gefunden." >&2
  exit 1
}

if have aussensensor-push; then
  echo "→ Push via aussensensor-push (NDJSON) → $INGEST_URL"
  AUSSENSENSOR_ARGS=("--url" "$INGEST_URL" "--file" "$FILE_PATH")
  # AUTH_TOKEN wird via CHRONIK_TOKEN Environment-Variable übergeben,
  # um Token in der Prozessliste (via --token) zu vermeiden.
  export CHRONIK_TOKEN="${AUTH_TOKEN}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    AUSSENSENSOR_ARGS+=("--dry-run")
  fi
  aussensensor-push "${AUSSENSENSOR_ARGS[@]}"
else
  need curl
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
  CURL_ARGS=("-sS" "-H" "content-type: $CONTENT_TYPE" "--data-binary" "@$FILE_PATH")
  if [[ -n "$AUTH_TOKEN" ]]; then
    CURL_ARGS+=("-H" "x-auth: $AUTH_TOKEN")
  fi
  tmp_body="$(mktemp "${TMPDIR:-/tmp}/aussensensor_push.XXXX")"
  cleanup() { rm -f "$tmp_body"; }
  trap cleanup EXIT

  # Technische Fehler (DNS, TLS, Verbindungsfehler, etc.)
  http_code="$(curl "${CURL_ARGS[@]}" -w "%{http_code}" -o "$tmp_body" "$INGEST_URL")" || {
    echo "Fehler: HTTP Request zu '$INGEST_URL' ist fehlgeschlagen." >&2
    echo "--- Antwort (falls vorhanden) ---" >&2
    sed 's/^/  /' "$tmp_body" >&2 || true
    echo "--------------------------------" >&2
    exit 1
  }

  # HTTP-Fehlercodes explizit behandeln
  if [[ "$http_code" -ge 400 ]]; then
    echo "Fehler: Server meldet HTTP $http_code für '$INGEST_URL'." >&2
    echo "--- Antwort des Servers ---" >&2
    sed 's/^/  /' "$tmp_body" >&2 || true
    echo "---------------------------" >&2
    exit 1
  fi

  # Erfolgsfall: Body an stdout, damit vorhandene Aufrufer weiterarbeiten können
  cat "$tmp_body"
  echo
fi
