#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
CONFIG_FILE="${AUSSENSENSOR_EXTERNAL_CONFIG:-$REPO_ROOT/config/external-sources.json}"
STATE_FILE="${AUSSENSENSOR_EXTERNAL_STATE:-$REPO_ROOT/.state/external-evidence.json}"
DRY_RUN="${AUSSENSENSOR_DRY_RUN:-0}"

STATE_DIR="${STATE_FILE%/*}"
if [[ "$STATE_DIR" == "$STATE_FILE" ]]; then
  STATE_DIR="."
fi
mkdir -p "$STATE_DIR"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/external-evidence.lock"
  if ! flock -n 9; then
    echo "aussensensor: another collection run owns the state lock" >&2
    exit 0
  fi
fi

NEXT_STATE="$(mktemp "$STATE_DIR/.external-evidence.next.XXXXXX.json")"
EVENT_FILE="$(mktemp "${TMPDIR:-/tmp}/aussensensor.external.XXXXXX.jsonl")"
cleanup() {
  if [[ -n "${NEXT_STATE:-}" ]]; then
    rm -f "$NEXT_STATE"
  fi
  rm -f "$EVENT_FILE"
}
trap cleanup EXIT INT TERM

"$PYTHON_BIN" "$SCRIPT_DIR/collect_external.py" \
  --config "$CONFIG_FILE" \
  --state "$STATE_FILE" \
  --next-state "$NEXT_STATE" \
  --output "$EVENT_FILE"

if [[ -s "$EVENT_FILE" ]]; then
  "$SCRIPT_DIR/validate.sh" "$EVENT_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    "$SCRIPT_DIR/push_chronik.sh" -f "$EVENT_FILE" --dry-run
    echo "aussensensor: dry-run; comparison state was not advanced"
    exit 0
  fi
  "$SCRIPT_DIR/push_chronik.sh" -f "$EVENT_FILE"
else
  echo "aussensensor: no relevant external change"
fi

mv -f "$NEXT_STATE" "$STATE_FILE"
NEXT_STATE=""
echo "aussensensor: comparison state advanced after successful delivery path"
