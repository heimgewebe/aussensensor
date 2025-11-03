### 📄 .env.example

**Größe:** 142 B | **md5:** `e3856752d01a594f16fd67ddac10ad51`

```plaintext
LEITSTAND_INGEST_URL=https://leitstand.example/ingest/aussen
LEITSTAND_TOKEN=changeme
HEIMLERN_INGEST_URL=http://localhost:8787/ingest/aussen
```

### 📄 .gitignore

**Größe:** 190 B | **md5:** `661b47e6654727a2ca0ec1e6c60710b2`

```plaintext
node_modules/
.DS_Store

# Stelle sicher, dass export/ und feed.jsonl versioniert werden dürfen
# (entferne ggf. ein globales export/*-Ignore).
!export/
!export/.gitkeep
!export/feed.jsonl
```

### 📄 README.md

**Größe:** 9 KB | **md5:** `b0713c55d0383986e68b1427a1534e51`

```markdown
# aussensensor

[![validate (aussensensor feed)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-feed.yml/badge.svg)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-feed.yml)
[![validate (aussen fixtures)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-aussen-fixtures.yml/badge.svg)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-aussen-fixtures.yml)

aussensensor kuratiert externe Informationsquellen (Newsfeeds, Wetter, Lagebilder) und stellt sie in einem konsistenten Ereignisformat für den Leitstand zur Verfügung. Die aktuelle Implementierung besteht aus einfachen Bash-Hilfsskripten, die den Feed in `export/feed.jsonl` pflegen und manuell an den Leitstand übertragen. Langfristig ist eine Migration zu einem dauerhaften Daemon geplant (siehe [docs/adr](docs/adr/README.md)).

## Systemkontext und Zielsetzung
- **Zielgruppe:** Operator:innen und Analyst:innen, die ein konsolidiertes Lagebild benötigen.
- **Einordnung:** aussensensor dient als vorgelagerter Kurationspunkt für externe Quellen und beliefert den Leitstand über die `/ingest/aussen`-Schnittstelle.
- **Datenfluss:** Quellen → Kurationsskripte → `export/feed.jsonl` → Push an Leitstand → Speicherung/Weiterverarbeitung im Leitstand.
Architekturentscheidungen, die zu diesem Design führten, sind in den [ADRs](docs/adr/README.md) dokumentiert.

## Komponentenüberblick
| Komponente | Beschreibung |
| --- | --- |
| `scripts/append-feed.sh` | Fügt dem Feed ein neues Ereignis im JSONL-Format hinzu und erzwingt Contract-Konformität. |
| `scripts/validate.sh` | Validiert eine JSONL-Datei gegen das Schema. |
| `scripts/push_leitstand.sh` | Überträgt den kompletten Feed an die Leitstand-Ingest-API oder führt einen Dry-Run aus. |
| `scripts/push_heimlern.sh` | Stößt den Push des Feeds an die Heimlern-Ingest-API an. |
| `contracts/aussen.event.schema.json` | JSON-Schema des Ereignisformats (Contract). |
| `export/feed.jsonl` | Sammeldatei aller kuratierten Ereignisse. |

> Hinweis: `export/feed.jsonl` enthält initial **eine** minimale Beispielzeile,
> damit die CI-Validierung sofort grün läuft. Ersetze/erweitere die Datei bei echter Nutzung.

## Voraussetzungen
- POSIX-kompatible Shell (getestet mit `bash`)
- `jq` ≥ 1.6 für JSON-Verarbeitung
- `curl` für HTTP-Requests
- Zugriff auf die Leitstand-Umgebung inkl. gültigem Token

## Einrichtung
1. Repository klonen und in das Projektverzeichnis wechseln.
2. Environment-Variablen setzen:
   - `LEITSTAND_INGEST_URL`: Basis-URL der Leitstand-Ingest-API (z. B. `https://leitstand.example/ingest/aussen`).
   - `HEIMLERN_INGEST_URL`: Endpoint der Heimlern-Ingest-API (z. B. `http://localhost:8787/ingest/aussen`).
   - Optional: `LEITSTAND_TOKEN` für einen statischen Token (Header `x-auth`).
3. Sicherstellen, dass `jq`, `curl` sowie (für Tests) `node`/`npx` installiert sind (`sudo apt install jq curl nodejs npm`).
4. (Für GitHub Actions) Repository-Secrets `LEITSTAND_INGEST_URL` und `LEITSTAND_TOKEN` setzen, damit der Workflow `Push feed to Leitstand` funktioniert.

## Nutzung (mit Runbook & CI)
Siehe [docs/runbook.md](docs/runbook.md). CI validiert `export/feed.jsonl` gegen den Contract.
### Ereignis hinzufügen
```bash
./scripts/append-feed.sh -t news -s rss:demo -T "Test" -S "Kurz" -u "https://example.org" -g "tag1,tag2"
# Für Positional-Mode siehe ./scripts/append-feed.sh -h
```
- `source`: Menschlich lesbarer Bezeichner (z. B. `heise`, `dwd`).
- `type`: Eine der Kategorien `news|sensor|project|alert`.
- `title`, `summary`, `url`: Inhalte des Ereignisses (`summary` ≤ 500 Zeichen). Bei fehlenden Angaben werden leere Strings geschrieben, um den Contract vollständig zu befüllen.
- `tags`: optionale Liste einzelner Tags (z. B. `rss:demo`, `topic:klima`). Das Skript serialisiert sie immer als JSON-Array (`[]`, wenn keine Tags übergeben wurden) und schreibt jede Zeile als kompaktes JSON-Objekt (NDJSON).
- Das Skript erzwingt Pflichtfelder, validiert Typen und prüft die Summary-Länge mit dem JSON-Schema, bevor der Eintrag in `export/feed.jsonl` angehängt wird.

Bei Eingabefehlern bricht das Skript mit einem nicht-null Exit-Code ab. Bereits vorhandene Einträge bleiben unverändert.

### Feed übertragen
```bash
export LEITSTAND_INGEST_URL="https://leitstand.example/ingest/aussen"
./scripts/push_leitstand.sh [--dry-run] [--file export/feed.jsonl] [--url "…"] [--token "$LEITSTAND_TOKEN"] [--content-type application/jsonl]
```
- Standardmäßig werden Ereignisse per `POST` im JSON Lines/NDJSON-Format übertragen mit `Content-Type: application/x-ndjson` (de-facto Standard und weit verbreitet).
- Bei Bedarf kann der Header überschrieben werden, entweder über `--content-type …` oder via Environment `CONTENT_TYPE=…`.
- Mit `--dry-run` wird nur ausgegeben, welche Daten gesendet würden; es erfolgt kein HTTP-Request.
- Das Skript liest URL und Token aus der Umgebung, akzeptiert aber auch explizite Argumente. Die Datei wird nicht verändert; `curl` erhält sie via `--data-binary`.

### Validierung & Tests
- Lokale Schema-Validierung (AJV, Draft 2020-12):

  ```bash
  ./scripts/validate.sh export/feed.jsonl
  ```

- Beim Append erzwingt das Skript Pflichtfelder, erlaubte Typen und die Summary-Länge laut Contract. Alle Events enthalten die Contract-Felder `ts`, `type`, `source`, `title`, `summary`, `url` und `tags`.
- GitHub Actions Workflows:
  - `Push feed to Leitstand` validiert jede Zeile mit AJV (mittels temporärer Kopie der Datei) und stößt manuell einen Push (optional als Dry-Run) an.
  - `validate (aussensensor)` prüft jede Feed-Zeile automatisiert gegen das Contract-Schema (inklusive Format-Checks) bei Pushes, Pull Requests und manuellen Runs.
  - `validate (aussen fixtures)` deckt Edge-Cases anhand der Beispiel-JSONL-Dateien unter `tests/fixtures/aussen/**` ab.

### Schneller Selbsttest
```bash
# Optional: Feed leeren, um nur den Test-Eintrag zu prüfen
# > export/feed.jsonl
./scripts/append-feed.sh -s heise -t news -T "Testtitel" -S "Kurztext" -u "https://example.org" -g "urgent,topic:klima,Berlin"
./scripts/validate.sh export/feed.jsonl
tail -n1 export/feed.jsonl | jq .
```
- Demonstriert, dass freie Tags (z. B. `topic:klima`) korrekt verarbeitet werden.
- Validiert den Feed direkt im Anschluss (siehe Schleife oben) und zeigt die zuletzt geschriebene Zeile einschließlich leerer Standardfelder.

## Ereignisschema & Datenqualität
- Pflichtfelder laut Contract: `ts` (ISO-8601), `type` (`news|sensor|project|alert`), `source`, `title`. Darüber hinaus werden `summary`, `url` und `tags[]` immer geschrieben (leere Strings bzw. leeres Array), damit Downstream-Services fixe Spalten haben.
- **Keine** zusätzlichen Felder erlaubt (`additionalProperties: false`).
- Tags sind freie Strings (z. B. `rss:demo`, `topic:klima`). Sie werden als JSON-Array geschrieben.
- Das Append-Skript setzt `ts` automatisch, serialisiert fehlende Tags als leeres Array und schreibt pro Ereignis eine NDJSON-Zeile.
- Fehlerhafte Zeilen können mit `jq` korrigiert und erneut validiert werden.
- Für NDJSON/JSONL empfiehlt sich `application/x-ndjson`. Einige Systeme akzeptieren auch `application/jsonl`; bei Bedarf kann der Push per Flag oder `CONTENT_TYPE` darauf umgestellt werden.

## Test-Fixtures & CI-Validierung
Für kontraktnahe Beispiele kannst du unter `tests/fixtures/aussen/*.jsonl` einzelne Ereignisse ablegen.
Ein dedizierter GitHub-Workflow validiert jede Datei einzeln gegen das Contract-Schema:

- Workflow: `.github/workflows/validate-aussen-fixtures.yml`
- Trigger: Änderungen unter `tests/fixtures/aussen/**` oder manueller Start
- Schema: `contracts/aussen.event.schema.json` (per Raw-URL aus dem metarepo gespiegelt)

Beispiel (lokal):
`npx -y ajv-cli@5 validate --spec=draft2020 --strict=false --validate-formats=false -s contracts/aussen.event.schema.json -d tests/fixtures/aussen/deinfall.jsonl`

## Betrieb & Monitoring
- **Logging:** Beide Skripte loggen in STDOUT/STDERR; für automatisierten Betrieb empfiehlt sich eine Umleitung nach `logs/` (z. B. via Cronjob).
- **Überwachung:**
  - Erfolgs-/Fehlercodes der Skripte in einen Supervisor (Systemd, Cron) integrieren.
  - GitHub Actions Workflow als manueller Run (z. B. nach größeren Änderungen) nutzen: Dry-Run prüfen, anschließend echten Push ausführen.
  - Feed-Größe und Alter der neuesten Einträge regelmäßig prüfen (`jq -r '.ts'`).
  - Leitstand-API-Responses lokal sichern (Follow-Up: `export/last_push_response.json`).
- **Ereignislebenszyklus:** Erfassung → Kuratierung im Feed → Push an Leitstand → Archivierung der verarbeiteten Zeilen (Rotation über zukünftigen Daemon).

## Roadmap (Auszug)
1. **Automatisierte Validierung** – umgesetzt via GitHub Actions (`Push feed to Leitstand`) als manueller Einstiegspunkt.
2. **Daemoni­sierung** gemäß ADR-0002: persistente Queue, Retry-Mechanismus, Backoff, Health Endpoint.
3. **Telemetrie**: strukturierte Logs und Metriken (z. B. Prometheus) für Anzahl/Alter der Ereignisse.
4. **Self-Service-Dokumentation**: Beispiele für neue Quellen, Onboarding-Checkliste.

Weitere Details und Entscheidungen sind in den [Architecture Decision Records](docs/adr/README.md) dokumentiert.
```

