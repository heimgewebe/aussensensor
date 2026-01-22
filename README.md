# aussensensor

[![validate (aussensensor feed)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-feed.yml/badge.svg)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-feed.yml)
[![validate (aussen fixtures)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-aussen-fixtures.yml/badge.svg)](https://github.com/heimgewebe/aussensensor/actions/workflows/validate-aussen-fixtures.yml)

aussensensor kuratiert externe Informationsquellen (Newsfeeds, Wetter, Lagebilder) und stellt sie in einem konsistenten Ereignisformat für die Chronik zur Verfügung. Die aktuelle Implementierung besteht aus einfachen Bash-Hilfsskripten, die den Feed in `export/feed.jsonl` pflegen und manuell an die Chronik übertragen. Langfristig ist eine Migration zu einem dauerhaften Daemon geplant (siehe [docs/adr](docs/adr/README.md)).

## Systemkontext und Zielsetzung
- **Zielgruppe:** Operatoren und Analysten, die ein konsolidiertes Lagebild benötigen.
- **Einordnung:** aussensensor dient als vorgelagerter Kurationspunkt für externe Quellen und beliefert die Chronik über die `/v1/ingest`-Schnittstelle.
- **Datenfluss:**
  **Zielbild (Standard)**: aussensensor → **nur** chronik `/v1/ingest`; Zustellung erfolgt via Plexer/Chronik gemäß `contracts/consumers.yaml`.
  **Legacy (deprecated)**: aussensensor → direkt **heimlern** (wird abgeschaltet).

  > Hinweis: Der direkte Heimlern-Pfad ist deprecated. Bevorzugter Pfad: **chronik**.
Architekturentscheidungen, die zu diesem Design führten, sind in den [ADRs](docs/adr/README.md) dokumentiert.

## Komponentenüberblick
| Komponente | Beschreibung |
| --- | --- |
| `scripts/append-feed.sh` | Fügt dem Feed ein neues Ereignis im JSONL-Format hinzu und erzwingt Contract-Konformität. |
| `scripts/validate.sh` | Validiert eine JSONL-Datei gegen das Schema. |
| `scripts/jsonl-compact.sh` | Kompaktifiziert JSONL-Dateien, indem jede Zeile als einzelnes JSON-Objekt formatiert wird. |
| `scripts/push_chronik.sh` | Überträgt den kompletten Feed an die Chronik-Ingest-API oder führt einen Dry-Run aus. |
| `scripts/push_heimlern.sh` | (Deprecated) Stößt den Push des Feeds an die Heimlern-Ingest-API an. |
| `contracts/aussen.event.schema.json` | JSON-Schema des Ereignisformats (Contract). |
| `export/feed.jsonl` | Sammeldatei aller kuratierten Ereignisse. |

> Hinweis: `export/feed.jsonl` enthält initial **eine** minimale Beispielzeile,
> damit die CI-Validierung sofort grün läuft. Ersetze/erweitere die Datei bei echter Nutzung.

## Voraussetzungen
- POSIX-kompatible Shell (getestet mit `bash`)
- `jq` ≥ 1.6 für JSON-Verarbeitung
- `curl` für HTTP-Requests
- `ajv-cli` (Node.js) für Validierung (`npm i -g ajv-cli@5.0.0`)
- Zugriff auf die Chronik-Umgebung inkl. gültigem Token

## Einrichtung
1. Repository klonen und in das Projektverzeichnis wechseln.
2. Environment-Variablen setzen:
   - `CHRONIK_INGEST_URL`: Basis-URL der Chronik-Ingest-API (z. B. `https://chronik.example/ingest/aussen`).
   - `HEIMLERN_INGEST_URL`: Endpoint der Heimlern-Ingest-API (z. B. `http://localhost:8787/ingest/aussen`).
   - Optional: `CHRONIK_TOKEN` für einen statischen Token (Header `x-auth`).
3. Sicherstellen, dass `jq`, `curl` sowie `node`/`npm` installiert sind.
4. `ajv-cli` installieren: `npm install -g ajv-cli@5.0.0`
5. **Optional**: Pre-commit Hooks für lokale Validierung installieren:
   ```bash
   pip install pre-commit
   pre-commit install
   ```
   Die Hooks führen automatisch shellcheck, YAML/JSON-Validierung und weitere Checks vor jedem Commit aus.
5. (Für GitHub Actions) Repository-Secrets `CHRONIK_INGEST_URL` und `CHRONIK_TOKEN` setzen, damit der Workflow `Push feed to Chronik` funktioniert.

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

### Push
Standard: `scripts/push_chronik.sh` (Zielarchitektur).

Legacy (Deprecated): `scripts/push_heimlern.sh`.
> **Achtung**: Dieses Skript ist deprecated und erfordert `ALLOW_HEIMLERN_MVP=1`.
> Es beendet sich mit Exit Code 2, wenn das Gate nicht explizit geöffnet ist.

Optional steht ein kleines Binary `aussensensor-push` bereit (Rust),
das NDJSON korrekt an `/v1/ingest` sendet. Die Skripte nutzen es,
falls vorhanden; sonst wird auf `curl` zurückgefallen.

### Validierung & Tests
- Lokale Schema-Validierung (AJV, Draft 2020-12):

  ```bash
  ./scripts/validate.sh export/feed.jsonl
  ```

- **JSONL-Kompaktifizierung**: Falls eine JSONL-Datei mehrzeilige oder unformatierte JSON-Objekte enthält, kann sie mit dem Kompaktifizierungs-Skript normalisiert werden:

  ```bash
  ./scripts/jsonl-compact.sh export/feed.jsonl
  ```

  Dies stellt sicher, dass jede Zeile ein einzelnes, kompaktes JSON-Objekt ist (NDJSON-konform).

- Beim Append erzwingt das Skript Pflichtfelder, erlaubte Typen und die Summary-Länge laut Contract. Alle Events enthalten die Contract-Felder `ts`, `type`, `source`, `title`, `summary`, `url` und `tags`.
- GitHub Actions Workflows:
  - `shellcheck` prüft alle Bash-Skripte auf häufige Fehler und Best Practices.
  - `tests` führt die automatisierte Testsuite (bats-core) aus.
  - `Push feed to Chronik` validiert jede Zeile mit AJV (mittels temporärer Kopie der Datei) und stößt manuell einen Push (optional als Dry-Run) an.
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

### Testing
This project uses `bats-core` for automated testing. The tests are located in the `tests/` directory. To run the test suite, execute the following command:

```bash
./tests/run.sh
```

### Build (optional)
```bash
cd tools/aussensensor-push
cargo build --release
sudo install -m 0755 target/release/aussensensor-push /usr/local/bin/
```
Die Push-Skripte verwenden das Binary automatisch, wenn vorhanden (sonst `curl`).

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
  - Chronik-API-Responses lokal sichern (Follow-Up: `export/last_push_response.json`).
- **Ereignislebenszyklus:** Erfassung → Kuratierung im Feed → Push an Chronik → Archivierung der verarbeiteten Zeilen (Rotation über zukünftigen Daemon).

## Roadmap (Auszug)
1. **Automatisierte Validierung** – umgesetzt via GitHub Actions (`Push feed to Chronik`) als manueller Einstiegspunkt.
2. **Daemoni­sierung** gemäß ADR-0002: persistente Queue, Retry-Mechanismus, Backoff, Health Endpoint.
3. **Telemetrie**: strukturierte Logs und Metriken (z. B. Prometheus) für Anzahl/Alter der Ereignisse.
4. **Self-Service-Dokumentation**: Beispiele für neue Quellen, Onboarding-Checkliste.

Eine detaillierte Evaluation und Optimierungsplan findet sich in [docs/evaluation.md](docs/evaluation.md).

Weitere Details und Entscheidungen sind in den [Architecture Decision Records](docs/adr/README.md) dokumentiert.

## MVP vs. Zielpfad
- **Legacy:** `scripts/push_heimlern.sh` (Direkt-Push) – DEPRECATED.
- **Ziel:** `scripts/push_chronik.sh` (nur chronik ingest) – Standard.

## Organismus-Kontext

Dieses Repository ist Teil des **Heimgewebe-Organismus**.

**Single Source of Truth:** `heimgewebe/metarepo` (`contracts/` + `contracts/consumers.yaml`). ADRs dokumentieren Entscheidungen, sind nicht SSOT.
aussensensor agiert als reiner Producer von Events; die Zustellung und das Routing an Consumer (wie Heimlern, Heimgeist etc.) obliegt dem Plexer/Chronik-Subsystem basierend auf den zentralen Contracts.

Die übergeordnete Architektur, Achsen, Rollen und Contracts sind zentral beschrieben im
👉 [`metarepo/docs/heimgewebe-organismus.md`](https://github.com/heimgewebe/metarepo/blob/main/docs/heimgewebe-organismus.md)
sowie im Zielbild
👉 [`metarepo/docs/heimgewebe-zielbild.md`](https://github.com/heimgewebe/metarepo/blob/main/docs/heimgewebe-zielbild.md).

Alle Rollen-Definitionen, Datenflüsse und Contract-Zuordnungen dieses Repos
sind dort verankert.
