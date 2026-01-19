#!/usr/bin/env bash
# MVP-WORKAROUND:
# Direkter Push zu heimlern. Zielarchitektur: ingest NUR via chronik.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_FILE="$REPO_ROOT/export/feed.jsonl"
CONTENT_TYPE="${CONTENT_TYPE:-application/x-ndjson}"
DRY_RUN="${DRY_RUN:-0}"
ALLOW_HEIMLERN_MVP="${ALLOW_HEIMLERN_MVP:-0}"
# Safety override for CI environments (double-lock)
ALLOW_HEIMLERN_MVP_CI="${ALLOW_HEIMLERN_MVP_CI:-0}"

normalize_bool() {
  case "${1:-}" in
  1 | true | yes | on) printf '1' ;;
  0 | false | no | off | '') printf '0' ;;
  *) return 1 ;;
  esac
}

if ! ALLOWED="$(normalize_bool "$ALLOW_HEIMLERN_MVP")"; then
  echo "Ungültiger Wert für ALLOW_HEIMLERN_MVP: $ALLOW_HEIMLERN_MVP" >&2
  exit 1
fi

if [[ "$ALLOWED" != "1" ]]; then
  echo "FEHLER: Dieses Skript ist deprecated und wird bald entfernt." >&2
  echo "Pending removal; replacement is Chronik ingest-only path via scripts/push_chronik.sh (consumer pull happens downstream)." >&2
  echo "Um diesen Legacy-Pfad dennoch zu nutzen, setze ALLOW_HEIMLERN_MVP=1." >&2
  exit 2
fi

# In CI environments, enforce a second lock to prevent accidental reactivation
if [[ "$(normalize_bool "${CI:-0}")" == "1" ]]; then
  if ! ALLOWED_CI="$(normalize_bool "$ALLOW_HEIMLERN_MVP_CI")"; then
     echo "Ungültiger Wert für ALLOW_HEIMLERN_MVP_CI: $ALLOW_HEIMLERN_MVP_CI" >&2
     exit 1
  fi
  if [[ "$ALLOWED_CI" != "1" ]]; then
    echo "FEHLER: Ausführung in CI blockiert (Double-Lock)." >&2
    echo "Bitte nutze 'scripts/push_chronik.sh'." >&2
    echo "Für Legacy-Nutzung in CI: Setze zusätzlich ALLOW_HEIMLERN_MVP_CI=1." >&2
    exit 2
  fi
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Fehlt: $1" >&2
    exit 1
  }
}

print_usage() {
  cat <<USAGE >&2
Usage: scripts/push_heimlern.sh [options] [feed.jsonl]

DEPRECATED: Bitte nutze scripts/push_chronik.sh.
Aktivierung nur mit ALLOW_HEIMLERN_MVP=1 möglich.

Exit Codes:
  0  Erfolg (oder Dry-Run OK)
  1  Allgemeiner Fehler (Konfiguration, fehlende Tools, Netzwerk)
  2  Deprecated/Blockiert (Gate hit)

Options:
  --content-type TYPE  Content-Type Header (Standard: ${CONTENT_TYPE})
  --dry-run             Nur Validierung, ohne Request (auch via DRY_RUN=1)
  -h, --help           Diese Hilfe anzeigen

Environment:
  HEIMLERN_INGEST_URL  Ziel-Endpoint (Pflicht)
  CONTENT_TYPE         Content-Type Header, falls --content-type fehlt
  DRY_RUN              Setze auf 1/true/yes/on für einen Dry-Run
  ALLOW_HEIMLERN_MVP   Setze auf 1, um dieses Skript auszuführen
  ALLOW_HEIMLERN_MVP_CI Setze auf 1, um CI-Blockade zu umgehen (wenn CI=true)
USAGE
}

FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --content-type)
    if [[ $# -lt 2 ]]; then
      echo "Fehlender Wert für --content-type" >&2
      exit 1
    fi
    CONTENT_TYPE="$2"
    shift 2
    ;;
  --dry-run)
    DRY_RUN="1"
    shift
    ;;
  -h | --help)
    print_usage
    exit 0
    ;;
  -*)
    echo "Unbekannte Option: $1" >&2
    print_usage
    exit 1
    ;;
  *)
    if [[ -n "$FILE" ]]; then
      echo "Mehr als eine Datei angegeben" >&2
      print_usage
      exit 1
    fi
    FILE="$1"
    shift
    ;;
  esac
done

FILE="${FILE:-$DEFAULT_FILE}"

if ! DRY_RUN="$(normalize_bool "$DRY_RUN")"; then
  echo "Ungültiger Wert für DRY_RUN: $DRY_RUN" >&2
  exit 1
fi

if [[ "$FILE" != /* ]]; then
  FILE="$(pwd)/$FILE"
fi

if [[ ! -f "$FILE" ]]; then
  echo "Fehler: Datei '$FILE' nicht gefunden." >&2
  exit 1
fi

if [[ -z "${CONTENT_TYPE//[[:space:]]/}" ]]; then
  echo "Fehler: Content-Type ist leer." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -n "${HEIMLERN_INGEST_URL:-}" ]]; then
    echo "[DRY-RUN] Würde POST an $HEIMLERN_INGEST_URL senden ($FILE, Content-Type: $CONTENT_TYPE)" >&2
  else
    echo "[DRY-RUN] Würde POST senden ($FILE, Content-Type: $CONTENT_TYPE); HEIMLERN_INGEST_URL ist nicht gesetzt" >&2
  fi
  exit 0
fi

need curl

: "${HEIMLERN_INGEST_URL:?set HEIMLERN_INGEST_URL}"

# Robust HTTP request implementation
tmp_body="$(mktemp "${TMPDIR:-/tmp}/heimlern_push.XXXX")"
cleanup() { rm -f "$tmp_body"; }
trap cleanup EXIT

http_code="$(curl -sS -o "$tmp_body" -w "%{http_code}" \
  -H "Content-Type: $CONTENT_TYPE" \
  --data-binary @"$FILE" \
  "$HEIMLERN_INGEST_URL")" || {
    echo "Fehler: HTTP Request zu '$HEIMLERN_INGEST_URL' ist fehlgeschlagen." >&2
    exit 1
}

if [[ "$http_code" -ge 400 ]]; then
  echo "Fehler: Server meldet HTTP $http_code für '$HEIMLERN_INGEST_URL'." >&2
  echo "--- Antwort des Servers ---" >&2
  sed 's/^/  /' "$tmp_body" >&2 || true
  echo "---------------------------" >&2
  exit 1
fi

echo "✅ Push erfolgreich (HTTP $http_code)"
