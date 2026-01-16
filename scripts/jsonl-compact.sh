#!/usr/bin/env bash
set -euo pipefail
#
# Kompaktifiziert *.jsonl: jede Zeile = valides, kompaktes JSON-Objekt.
# Nutzung:
#   scripts/jsonl-compact.sh export/feed.jsonl
#
file="${1:-}"
if [[ -z "$file" || ! -f "$file" ]]; then
  echo "Fehler: usage: $0 <file.jsonl>" >&2
  exit 2
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/jsonl_compact.${file##*/}.XXXX")"
trap 'rm -f "$tmp"' EXIT

# In kompaktes JSON (-c) konvertieren; invalide Eingabe bricht ab.
jq -c . "$file" > "$tmp"

mv -f -- "$tmp" "$file"
echo "compacted: $file"
