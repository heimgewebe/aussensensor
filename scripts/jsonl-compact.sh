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

# Zeilenweise lesen, in kompaktes JSON (-c) konvertieren; invalide Zeilen brechen ab.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line// /}" ]] || continue
  printf '%s\n' "$line" | jq -e -c . >>"$tmp"
done <"$file"

mv -f -- "$tmp" "$file"
echo "compacted: $file"
