#!/usr/bin/env bash
# MVP-WORKAROUND:
# Direkter Push zu heimlern. Zielarchitektur: ingest NUR via leitstand.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_FILE="$REPO_ROOT/export/feed.jsonl"
CONTENT_TYPE="${CONTENT_TYPE:-application/x-ndjson}"
DRY_RUN="${DRY_RUN:-0}"

print_usage() {
  cat <<USAGE >&2
Usage: scripts/push_heimlern.sh [options] [feed.jsonl]

Options:
  --content-type TYPE  Content-Type Header (Standard: ${CONTENT_TYPE})
  --dry-run             Nur Validierung, ohne Request (auch via DRY_RUN=1)
  -h, --help           Diese Hilfe anzeigen

Environment:
  HEIMLERN_INGEST_URL  Ziel-Endpoint (Pflicht)
  CONTENT_TYPE         Content-Type Header, falls --content-type fehlt
  DRY_RUN              Setze auf 1/true/yes/on für einen Dry-Run
USAGE
}

normalize_bool() {
  case "${1:-}" in
  1 | true | TRUE | yes | YES | on | ON)
    printf '1'
    ;;
  0 | false | FALSE | no | NO | off | OFF | '')
    printf '0'
    ;;
  *)
    return 1
    ;;
  esac
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

if [[ $# -gt 0 ]]; then
  echo "Zu viele Argumente: $*" >&2
  print_usage
  exit 1
fi

FILE="${FILE:-$DEFAULT_FILE}"

if ! DRY_RUN="$(normalize_bool "$DRY_RUN")"; then
  echo "Ungültiger Wert für DRY_RUN: $DRY_RUN" >&2
  exit 1
fi

if [[ "$FILE" != /* ]]; then
  FILE="$(pwd)/$FILE"
fi

if [[ ! -f "$FILE" ]]; then
  echo "missing $FILE" >&2
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

command -v curl >/dev/null 2>&1 || {
  echo "Fehlt: curl" >&2
  exit 1
}

: "${HEIMLERN_INGEST_URL:?set HEIMLERN_INGEST_URL}"

curl --fail --silent --show-error --request POST "$HEIMLERN_INGEST_URL" \
  --header "Content-Type: $CONTENT_TYPE" \
  --data-binary @"$FILE" \
  --write-out '\nHTTP:%{http_code}\n'

echo "✅ Push erfolgreich"
