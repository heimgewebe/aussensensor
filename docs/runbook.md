# Runbook (operativ)
- Feed pflegen mit `scripts/append-feed.sh`.
- Vor Push: `scripts/validate.sh export/feed.jsonl`.
- Übertragen: `scripts/push_leitstand.sh --dry-run` (vorher ENV setzen).
- Notfall: Feed einfrieren, invalidierende Einträge entfernen, erneut validieren.
