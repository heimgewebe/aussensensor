# aussensensor

aussensensor kuratiert externe Informationsquellen (Newsfeeds, Wetter, Lagebilder) und stellt sie in einem konsistenten Ereignisformat für den Leitstand zur Verfügung. Die aktuelle Implementierung besteht aus einfachen Bash-Hilfsskripten, die den Feed in `export/feed.jsonl` pflegen und manuell an den Leitstand übertragen. Langfristig ist eine Migration zu einem dauerhaften Daemon geplant (siehe [docs/adr](docs/adr/README.md)).

## Systemkontext und Zielsetzung
- **Zielgruppe:** Operator:innen und Analyst:innen, die ein konsolidiertes Lagebild benötigen.
- **Einordnung:** aussensensor dient als vorgelagerter Kurationspunkt für externe Quellen und beliefert den Leitstand über die `/ingest/aussen`-Schnittstelle.
- **Datenfluss:** Quellen → Kurationsskripte → `export/feed.jsonl` → Push an Leitstand → Speicherung/Weiterverarbeitung im Leitstand.

## Komponentenüberblick
| Komponente | Beschreibung |
| --- | --- |
| `scripts/append-feed.sh` | Fügt dem Feed ein neues Ereignis im JSONL-Format hinzu. |
| `scripts/push_leitstand.sh` | Überträgt den kompletten Feed an die Leitstand-Ingest-API. |
| `contracts/aussen.event.schema.json` | JSON-Schema des Ereignisformats (Contract). |
| `export/feed.jsonl` | Sammeldatei aller kuratierten Ereignisse. |

## Voraussetzungen
- POSIX-kompatible Shell (getestet mit `bash`)
- `jq` ≥ 1.6 für JSON-Verarbeitung
- `curl` für HTTP-Requests
- Zugriff auf die Leitstand-Umgebung inkl. gültigem Token

## Einrichtung
1. Repository klonen und in das Projektverzeichnis wechseln.
2. Environment-Variablen setzen:
   - `LEITSTAND_INGEST_URL`: Basis-URL der Leitstand-Ingest-API (z. B. `https://leitstand.example/ingest/aussen`).
   - Optional: `LEITSTAND_TOKEN` für einen statischen Bearer-Token, falls nicht interaktiv abgefragt werden soll.
3. Sicherstellen, dass `jq` und `curl` installiert sind (`sudo apt install jq curl`).

## Nutzung
### Ereignis hinzufügen
```bash
./scripts/append-feed.sh -t news -s rss:demo -T "Test" -S "Kurz" -u "https://example.org" -g "tag1,tag2"
# For more options, run ./scripts/append-feed.sh -h
export LEITSTAND_INGEST_URL="https://<leitstand-url>/ingest/aussen"
./scripts/push_leitstand.sh 1
```
- `source`: Menschlich lesbarer Bezeichner (z. B. `heise`, `dwd`).
- `type`: Eine der Kategorien `news|sensor|project|alert`.
- `title`, `summary`, `url`: Inhalte des Ereignisses (`summary` ≤ 500 Zeichen).
- `tags`: optionale Liste einzelner Tags (z. B. `rss:demo klima berlin`).
- Das Skript validiert Eingaben mit `jq` und lehnt leere Felder ab.

Bei Eingabefehlern bricht das Skript mit einem nicht-null Exit-Code ab. Bereits vorhandene Einträge bleiben unverändert.

### Feed übertragen
```bash
export LEITSTAND_INGEST_URL="https://leitstand.example/ingest/aussen"
./scripts/push_leitstand.sh [--dry-run] [--token "$LEITSTAND_TOKEN"]
```
- Standardmäßig werden Ereignisse per `POST` im JSONL-Format übertragen.
- Mit `--dry-run` wird nur ausgegeben, welche Daten gesendet würden.
- Fehlgeschlagene Übertragungen werden protokolliert; das Skript liefert einen Fehlercode, sodass CI/Automatisierung reagieren kann.

### Validierung & Tests
- Lokale Schema-Validierung (AJV, Draft 2020-12):

  ```bash
  npx -y ajv-cli@5 validate -s contracts/aussen.event.schema.json -d export/feed.jsonl
  ```

- Beim Append erzwingt das Skript Pflichtfelder, erlaubte Typen und die Summary-Länge laut Contract.

### Schneller Selbsttest
```bash
./scripts/append-feed.sh heise news "Testtitel" "Kurztext" "https://example.org" --urgent topic:klima Berlin
npx -y ajv-cli@5 validate -s contracts/aussen.event.schema.json -d export/feed.jsonl
tail -n1 export/feed.jsonl | jq .
```
- Demonstriert, dass ungewöhnliche Tags (z. B. beginnend mit `-`) korrekt verarbeitet werden.
- Validiert den Feed direkt im Anschluss und zeigt die zuletzt geschriebene Zeile.

## Ereignisschema & Datenqualität
- Pflichtfelder laut Contract: `ts` (ISO-8601), `type` (`news|sensor|project|alert`), `source`, `title`, `summary` (≤ 500), `url`, `tags[]`.
- **Keine** zusätzlichen Felder erlaubt (`additionalProperties: false`).
- Tags sind freie Strings (z. B. `rss:demo`, `topic:klima`). Sie werden als JSON-Array geschrieben.
- Das Append-Skript setzt `ts` automatisch und serialisiert fehlende Tags als leeres Array.
- Fehlerhafte Zeilen können mit `jq` korrigiert und erneut validiert werden.

## Betrieb & Monitoring
- **Logging:** Beide Skripte loggen in STDOUT/STDERR; für automatisierten Betrieb empfiehlt sich eine Umleitung nach `logs/` (z. B. via Cronjob).
- **Überwachung:**
  - Erfolgs-/Fehlercodes der Skripte in einen Supervisor (Systemd, Cron) integrieren.
  - Leitstand-API-Responses werden gespeichert (`export/last_push_response.json` geplant); fehlerhafte Antworten lösen Alerts aus.
  - Feed-Größe und Alter der neuesten Einträge regelmäßig prüfen (`jq -r '.ts'`).
- **Ereignislebenszyklus:** Erfassung → Kuratierung im Feed → Push an Leitstand → Archivierung der verarbeiteten Zeilen (Rotation über zukünftigen Daemon).

## Roadmap (Auszug)
1. **Automatisierte Validierung** in CI gegen das JSON-Schema.
2. **Daemoni­sierung** gemäß ADR-0002: persistente Queue, Retry-Mechanismus, Backoff, Health Endpoint.
3. **Telemetrie**: strukturierte Logs und Metriken (z. B. Prometheus) für Anzahl/Alter der Ereignisse.
4. **Self-Service-Dokumentation**: Beispiele für neue Quellen, Onboarding-Checkliste.

Weitere Details und Entscheidungen sind in den [Architecture Decision Records](docs/adr/README.md) dokumentiert.
