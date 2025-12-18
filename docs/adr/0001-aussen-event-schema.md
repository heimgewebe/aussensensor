# ADR-0001: Event-Format `aussen.event.schema.json` (kuratierter Feed)
Status: Accepted  
Date: 2025-10-12

## Kontext
- Externe Informationsquellen liefern heterogene Formate (RSS, HTML-Scrapes, manuelle Meldungen).
- Die Chronik erwartet klar strukturierte Ereignisse, um automatisierte Auswertung und Priorisierung zu ermöglichen.
- Kurator:innen sollen Einträge ohne tiefes Technikverständnis beisteuern können.

## Entscheidung
- Alle Einträge werden als JSON Lines (`export/feed.jsonl`) gespeichert, **eine Zeile = ein Event**.
- Contract [`contracts/aussen.event.schema.json`](../../contracts/aussen.event.schema.json) (Draft 2020-12) ist die Quelle der Wahrheit.
  - Schema-Pflichtfelder (minimal, stabil): `type` (`string`), `source` (`string`, `minLength: 1`).
  - Bedingte Pflicht (per Schema-Regel): Wenn `type == "link"`, dann ist `url` Pflicht (`string`, `format: uri`).
  - Stark empfohlene Felder (für gute Nutzbarkeit, aber nicht überall erzwingbar): `ts` (`string`, `format: date-time`), `title` (`string`, `minLength: 1`), `url` (`string`, `format: uri`), `summary` (`string`, `maxLength: 2000`), `tags` (`array<string>`, `uniqueItems: true`).
- `scripts/append-feed.sh` setzt `ts` automatisch, prüft `type`, Summary-Länge und Tags und erzeugt strikt schema-konforme Objekte.
- Schema-Versionierung erfolgt über Git-Tags im Contracts-Repo; Erweiterungen werden als neue Schema-Dateien ergänzt.
- Validierung lokal und in CI per `ajv-cli`; Feed-Einträge müssen `additionalProperties: false` erfüllen.

## Konsequenzen
- Einheitliche Datenstruktur ermöglicht einfache Aggregation und spätere Migration in einen Daemon.
- Kurator:innen haben klare Leitplanken, welche Felder wie zu füllen sind; Fehlbedienung wird früh entdeckt.
- Erweiterungen erfordern Schema-Pflege und Dokumentation (Release Notes im Repo).
- Monitoring kann sich auf Schema-Pflichtfelder verlassen; für Auswertungen sollten `ts` und `tags` nach Möglichkeit immer gesetzt werden.

## Implementierungsnotizen
- `append-feed.sh` nutzt `jq -nc` zum Erzeugen der JSON-Objekte und `date -Iseconds` für `ts`; Tags werden als JSON-Array aus CLI-Argumenten gebaut.
- Bei Schema-Änderungen neue Schema-Versionen im Contracts-Monorepo anlegen und Feed-Einträge per Skript migrieren (Downtime vermeiden).
- Künftige Daemon-Versionen konsumieren das Schema in Contract-Tests und validieren eingehende Quellen vor Persistierung.

## Alternativen
- Unstrukturiertes Free-Text-Log (verworfen: erschwerte Automatisierung).
- Formatierung über CSV (verworfen: unzureichende Ausdrucksmächtigkeit für verschachtelte Felder und Anhänge).

## Hinweis zur Format-Validierung (URI)
- Wenn in CI oder lokal `ajv` mit `--validate-formats=false` läuft, wird `format: uri` nicht geprüft.
- Für höhere Datenqualität kann man `--validate-formats=true` aktivieren; dann sind leere Strings bei `url` automatisch ungültig.
