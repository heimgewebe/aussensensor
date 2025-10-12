# ADR-0001: Event-Format `aussen.event.schema.json` (kuratierter Feed)
Status: Accepted
Date: 2025-10-12

## Kontext
Außenquellen sollen einheitlich in den Fleet-Fluss.

## Entscheidung
- Kuratierter Feed `export/feed.jsonl` nach Schema.

## Konsequenzen
- Einheitliche Ingest-Pipeline in leitstand.
- Qualität durch Kuratierung.

## Alternativen
- Rohdaten ungefiltert: verworfen.
