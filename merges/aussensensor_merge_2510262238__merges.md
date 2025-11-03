### 📄 merges/aussensensor_merge_2510262237__.github_workflows.md

**Größe:** 7 KB | **md5:** `491b5226509ab32f0833949ca39e3edc`

```markdown
### 📄 .github/workflows/contracts-validate.yml

**Größe:** 187 B | **md5:** `dca48dea5be7bde5fa5ca44dae67795f`

```yaml
name: contracts-validate
permissions:
  contents: read

on:
  push:
  pull_request:

jobs:
  validate:
    uses: heimgewebe/metarepo/.github/workflows/contracts-validate.yml@contracts-v1
```

### 📄 .github/workflows/jsonl-guard.yml

**Größe:** 2 KB | **md5:** `5e3a3c7836b3648afd40fdf3437c91ba`

```yaml
name: jsonl-guard
on:
  push:
    paths:
      - "**/*.jsonl"
      - ".github/workflows/jsonl-guard.yml"
  pull_request:
    paths:
      - "**/*.jsonl"
      - ".github/workflows/jsonl-guard.yml"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install jq
        run: sudo apt-get update && sudo apt-get install -y jq
      - name: Ensure JSONL lines are single, valid JSON objects
        shell: bash
        run: |
          shopt -s globstar nullglob
          failed=0
          for f in **/*.jsonl; do
            echo "::group::check $f"
            lineno=0
            while IFS= read -r line || [[ -n "$line" ]]; do
              lineno=$((lineno+1))
              [[ -n "${line// }" ]] || continue
              if ! printf '%s\n' "$line" | jq -e . >/dev/null 2>&1; then
                echo "::error file=$f,line=$lineno::Invalid JSON (line must be a complete JSON object)."
                failed=1
              fi
              # Fail if the object appears split across multiple lines (heuristic: trailing comma or open brace-only)
              [[ "$line" =~ ,[[:space:]]*$ ]] && { echo "::error file=$f,line=$lineno::Line ends with comma -> multiline JSON not allowed."; failed=1; }
              [[ "$line" =~ ^[[:space:]]*[{[]?[[:space:]]*$ ]] && { echo "::warning file=$f,line=$lineno::Suspicious structural-only line."; failed=1; }
            done < "$f"
            echo "::endgroup::"
          done
          exit $failed
```

### 📄 .github/workflows/push_leitstand.yml

**Größe:** 2 KB | **md5:** `ef7f8a536f4a80cc35f20d6b0d14575d`

```yaml
name: Push feed to Leitstand
permissions:
  contents: read

on:
  workflow_dispatch:
    inputs:
      url:
        description: "Optional: Override Leitstand ingest URL"
        required: false
        type: string
      dry_run:
        description: "Nur Testlauf ohne HTTP-Request"
        required: false
        default: false
        type: boolean

jobs:
  push:
    name: Validate and push feed
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Validate feed against schema
        run: |
          set -euo pipefail
          if [ ! -f export/feed.jsonl ] || [ ! -s export/feed.jsonl ]; then
            echo "Keine Einträge in export/feed.jsonl – Validierung übersprungen."
            exit 0
          fi
          tmp_dir="$(mktemp -d)"
          trap 'rm -rf "$tmp_dir"' EXIT
          cp export/feed.jsonl "$tmp_dir/feed.jsonl"
          while IFS= read -r line || [ -n "$line" ]; do
            if [ -z "${line// }" ]; then
              continue
            fi
            printf '%s\n' "$line" > export/feed.jsonl
            npx -y ajv-cli@5 validate --spec=draft2020 --strict=false --validate-formats=false -s contracts/aussen.event.schema.json -d export/feed.jsonl
          done < "$tmp_dir/feed.jsonl"
          mv "$tmp_dir/feed.jsonl" export/feed.jsonl

      - name: Push feed to Leitstand
        env:
          LEITSTAND_INGEST_URL: ${{ inputs.url != '' && inputs.url || secrets.LEITSTAND_INGEST_URL }}
          LEITSTAND_TOKEN: ${{ secrets.LEITSTAND_TOKEN }}
        run: |
          set -euo pipefail
          DRY_RUN_FLAG=""
          if [ "${{ inputs.dry_run }}" = 'true' ]; then
            DRY_RUN_FLAG="--dry-run"
          fi
          scripts/push_leitstand.sh $DRY_RUN_FLAG
```

### 📄 .github/workflows/validate-aussen-fixtures.yml

**Größe:** 2 KB | **md5:** `abd4a12563c883ee595aff21ecb56404`

```yaml
name: validate (aussen fixtures)

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

on:
  push:
    paths:
      - 'tests/fixtures/aussen/**'
      - '.github/workflows/validate-aussen-fixtures.yml'
  pull_request:
    paths:
      - 'tests/fixtures/aussen/**'
      - '.github/workflows/validate-aussen-fixtures.yml'
  workflow_dispatch:

jobs:
  discover:
    name: Discover fixture files
    runs-on: ubuntu-latest
    outputs:
      files: ${{ steps.collect.outputs.files }}
    steps:
      - uses: actions/checkout@v4
      - id: collect
        shell: bash
        run: |
          shopt -s nullglob
          arr=(tests/fixtures/aussen/*.jsonl)
          if [ ${#arr[@]} -eq 0 ]; then
            echo "files=[]" >> "$GITHUB_OUTPUT"
            echo "No fixtures found."
            exit 0
          fi
          printf 'files=[' >> "$GITHUB_OUTPUT"
          first=1
          for f in "${arr[@]}"; do
            if [ $first -eq 1 ]; then first=0; else printf ',' >> "$GITHUB_OUTPUT"; fi
            printf '%s' "\"$f\"" >> "$GITHUB_OUTPUT"
          done
          printf ']\n' >> "$GITHUB_OUTPUT"
          echo "Discovered ${#arr[@]} fixture file(s)."

  validate:
    name: Validate ${{ matrix.file }}
    needs: discover
    if: ${{ fromJSON(needs.discover.outputs.files) != null && length(fromJSON(needs.discover.outputs.files)) > 0 }}
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    strategy:
      fail-fast: false
      matrix:
        file: ${{ fromJSON(needs.discover.outputs.files) }}
    with:
      # Reusable erwartet ggf. einen einzelnen Pfad:
      jsonl_path: ${{ matrix.file }}
      # Falls die Reusable zusätzlich strict/validate_formats unterstützt, kann man sie dort aktivieren;
      # werte ignoriert die Reusable einfach.
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```

### 📄 .github/workflows/validate-feed.yml

**Größe:** 789 B | **md5:** `30320262e5f4b3905dcc447672e7ea63`

```yaml
name: validate (aussensensor feed)

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

on:
  push:
    paths:
      - export/feed.jsonl
      - .github/workflows/validate-feed.yml
      - contracts/**
      - scripts/validate.sh
  pull_request:
    paths:
      - export/feed.jsonl
      - .github/workflows/validate-feed.yml
      - contracts/**
      - scripts/validate.sh
  workflow_dispatch:
jobs:
  validate:
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    with:
      jsonl_path: export/feed.jsonl
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```

### 📄 .github/workflows/validate.yml

**Größe:** 419 B | **md5:** `eeea55413117a04030cc80424b64c67b`

```yaml
name: validate (aussensensor)
on: [push, pull_request, workflow_dispatch]
permissions:
  contents: read
jobs:
  v:
    uses: heimgewebe/metarepo/.github/workflows/reusable-validate-jsonl.yml@contracts-v1
    with:
      jsonl_path: export/feed.jsonl
      schema_url: https://raw.githubusercontent.com/heimgewebe/metarepo/contracts-v1/contracts/aussen.event.schema.json
      strict: false
      validate_formats: true
```
```

### 📄 merges/aussensensor_merge_2510262237__contracts.md

**Größe:** 716 B | **md5:** `530dcad8a5309e6545599dcd6e708fb7`

```markdown
### 📄 contracts/aussen.event.schema.json

**Größe:** 592 B | **md5:** `dcee2f38eef9973cfee5f4b930517d74`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "aussensensor/weltgewebe event",
  "type": "object",
  "required": ["ts", "type", "source", "title"],
  "properties": {
    "ts": { "type": "string", "format": "date-time" },
    "type": { "type": "string", "enum": ["news", "sensor", "project", "alert"] },
    "source": { "type": "string" },
    "title": { "type": "string" },
    "summary": { "type": "string", "maxLength": 500 },
    "url": { "type": "string" },
    "tags": { "type": "array", "items": { "type": "string" } }
  },
  "additionalProperties": false
}
```
```

### 📄 merges/aussensensor_merge_2510262237__docs.md

**Größe:** 4 KB | **md5:** `b971ae7a2a55599923589c2952d2cf7c`

```markdown
### 📄 docs/runbook.md

**Größe:** 4 KB | **md5:** `00ec1d9f1af88522e0643807650c987e`

```markdown
# Betriebs-Runbook

Dieses Runbook beschreibt den täglichen Ablauf für das Kuratieren und Ausliefern des `export/feed.jsonl` sowie die Vorgehensweise bei einem Änderungsfreeze.

## Rollen & Voraussetzungen
- **Operator:in (On-Call):** Verantwortlich für Pflege und Auslieferung des Feeds.
- Zugriff auf dieses Repository inklusive Schreibrechten.
- Lokale Umgebung mit `bash`, `jq` ≥ 1.6 und `curl` (siehe [README](../README.md)).
- GitHub Actions Status im Blick behalten (Badges im README oder Reiter *Actions*).

## Standardablauf: Append → Validate → Push
1. **Arbeitskopie aktualisieren**
   ```bash
   git pull --rebase
   ```
2. **Neues Ereignis anhängen**
   ```bash
   ./scripts/append-feed.sh -s <source> -t <type> -T "<title>" -S "<summary>" -u "<url>" -g "tag1,tag2"
   ```
   - Prüft Pflichtfelder, maximale Summary-Länge und das JSON-Schema, bevor geschrieben wird.
   - Tags können auch positional übergeben werden (`./scripts/append-feed.sh <source> <type> …`).
3. **Gesamten Feed validieren**
   ```bash
   ./scripts/validate.sh export/feed.jsonl
   ```
   - Nutzt `ajv` (per `npx`) gegen `contracts/aussen.event.schema.json`.
   - Bei Fehlern: betroffene Zeile mit `jq` korrigieren und erneut validieren.
4. **Änderung committen & pushen**
   ```bash
   git status
   git add export/feed.jsonl
   git commit -m "Append <kurzer Kontext>"
   git push
   ```
5. **CI überwachen**
   - Workflow `validate (aussensensor feed)` läuft automatisch für `export/feed.jsonl` und verwendet das reusable Workflow-Template `reusable-validate-jsonl.yml@contracts-v1` mit dem Schema `contracts/aussen.event.schema.json`.
   - Zusätzlich prüft der Workflow [`jsonl-guard`](../.github/workflows/jsonl-guard.yml) jede `.jsonl`-Datei auf korrektes NDJSON-Format (`jq` stellt sicher, dass jede Zeile ein vollständiges JSON-Objekt ist).
   - Erst wenn beide Workflows grün sind, gilt der Feed als freigegeben.
6. **Feed übertragen (falls erforderlich)**
   ```bash
   export LEITSTAND_INGEST_URL="https://leitstand.example/ingest/aussen"
   ./scripts/push_leitstand.sh --dry-run   # zum Testen
   ./scripts/push_leitstand.sh             # produktiver Push
   ```
   - Token via `LEITSTAND_TOKEN` setzen oder Flag `--token` nutzen.
   - Dry-Run prüfen, danach echten Push ausführen.

## Änderungsfreeze / Freeze-Prozedur
Wenn der Feed eingefroren werden muss (z. B. vor einem Incident-Review oder wegen ungeklärter Validierungsfehler):
1. **Kommunizieren**
   - Im Teamkanal (z. B. `#leitstand`) Freeze ankündigen und Grund nennen.
   - Issue oder Incident-Notiz im Repository anlegen.
2. **Freeze markieren**
   - Branch `freeze/<datum>-<kurzgrund>` erstellen.
   - Datei `export/feed.jsonl` in `main` nicht mehr verändern.
   - Optional: GitHub Environment "freeze" nutzen (falls vorhanden) und Deployment blockieren.
3. **CI überwachen**
   - `validate (aussensensor feed)` muss zuletzt grün gelaufen sein; bei roten Läufen *kein* Push an den Leitstand.
   - Offene Pull Requests pausieren (Draft-Status setzen).
4. **Freeze beenden**
   - Ursache analysieren und beheben (z. B. invalide Zeile entfernen/reparieren).
   - PR/Merge in `main`, anschließend Workflows abwarten.
   - Freeze im Teamkanal und Issue schließen.

## Troubleshooting
- **CI schlägt fehl (Schema-Fehler):**
  - Ausgabe in GitHub Actions prüfen (`validate (aussensensor feed)` gibt Dateiname und Zeilennummer aus).
  - Lokal `./scripts/validate.sh export/feed.jsonl` ausführen, Zeile mit `sed -n '<nr>p'` inspizieren.
- **jsonl-guard meldet Fehler:**
  - Zeile ist kein vollständiges JSON-Objekt. Mit `jq -c .` gegenprüfen und sicherstellen, dass keine Mehrzeilen-Objekte entstehen.
- **Push-Skript schlägt fehl:**
  - HTTP-Status prüfen. Bei Auth-Fehlern Token aktualisieren, bei Netzwerkproblemen Dry-Run nutzen und später erneut versuchen.
- **Mehrere Personen arbeiten parallel:**
  - Änderungen sequenziell mergen (rebase), um Feed-Konflikte zu vermeiden.
  - Konflikte mit `jq -s` zusammenführen (`jq -s '.[]' export/feed.jsonl other.jsonl > export/feed.jsonl`).

## Checkliste vor Schichtende
- Offene Änderungen committed und gepusht?
- Letzte CI-Läufe grün?
- Leitstand mit aktuellem Feed versorgt (falls notwendig)?
- Offene Incidents oder Freeze-Status dokumentiert?
```
```

### 📄 merges/aussensensor_merge_2510262237__docs_adr.md

**Größe:** 5 KB | **md5:** `dd1cf15d81f85f157b15d94648ed8f7d`

```markdown
### 📄 docs/adr/0001-aussen-event-schema.md

**Größe:** 2 KB | **md5:** `904acf03b8c7b3363c8545e64c73d2fa`

```markdown
# ADR-0001: Event-Format `aussen.event.schema.json` (kuratierter Feed)
Status: Accepted  
Date: 2025-10-12

## Kontext
- Externe Informationsquellen liefern heterogene Formate (RSS, HTML-Scrapes, manuelle Meldungen).
- Der Leitstand erwartet klar strukturierte Ereignisse, um automatisierte Auswertung und Priorisierung zu ermöglichen.
- Kurator:innen sollen Einträge ohne tiefes Technikverständnis beisteuern können.

## Entscheidung
- Alle Einträge werden als JSON Lines (`export/feed.jsonl`) gespeichert, **eine Zeile = ein Event**.
- Contract [`contracts/aussen.event.schema.json`](../../contracts/aussen.event.schema.json) (Draft 2020-12) mit Pflichtfeldern:
  - `ts` (`string`, `format: date-time`)
  - `type` (`"news"|"sensor"|"project"|"alert"`)
  - `source` (`string`)
  - `title` (`string`)
  - `summary` (`string`, `maxLength: 500`)
  - `url` (`string`)
  - `tags` (`array<string>`)
- `scripts/append-feed.sh` setzt `ts` automatisch, prüft `type`, Summary-Länge und Tags und erzeugt strikt schema-konforme Objekte.
- Schema-Versionierung erfolgt über Git-Tags im Contracts-Repo; Erweiterungen werden als neue Schema-Dateien ergänzt.
- Validierung lokal und in CI per `ajv-cli`; Feed-Einträge müssen `additionalProperties: false` erfüllen.

## Konsequenzen
- Einheitliche Datenstruktur ermöglicht einfache Aggregation und spätere Migration in einen Daemon.
- Kurator:innen haben klare Leitplanken, welche Felder wie zu füllen sind; Fehlbedienung wird früh entdeckt.
- Erweiterungen erfordern Schema-Pflege und Dokumentation (Release Notes im Repo).
- Monitoring kann sich auf Pflichtfelder verlassen (z. B. Alter über `ts`, Quellenverteilung über `tags`).

## Implementierungsnotizen
- `append-feed.sh` nutzt `jq -nc` zum Erzeugen der JSON-Objekte und `date -Iseconds` für `ts`; Tags werden als JSON-Array aus CLI-Argumenten gebaut.
- Bei Schema-Änderungen neue Schema-Versionen im Contracts-Monorepo anlegen und Feed-Einträge per Skript migrieren (Downtime vermeiden).
- Künftige Daemon-Versionen konsumieren das Schema in Contract-Tests und validieren eingehende Quellen vor Persistierung.

## Alternativen
- Unstrukturiertes Free-Text-Log (verworfen: erschwerte Automatisierung).
- Formatierung über CSV (verworfen: unzureichende Ausdrucksmächtigkeit für verschachtelte Felder und Anhänge).
```

### 📄 docs/adr/0002-mvp-to-daemon.md

**Größe:** 2 KB | **md5:** `6fde601ee1be5a4e43bc2600b6f388da`

```markdown
# ADR-0002: MVP Bash+jq → kleiner Daemon (Rust/Python)
Status: Accepted  
Date: 2025-10-12

## Kontext
- Aktuell werden Ereignisse manuell oder per Cron mit Bash-Skripten gesammelt und übertragen.
- Zunehmende Quellanzahl (RSS, API, Scraper) führt zu höherer Frequenz und Bedarf an Retries/Rate-Limits.
- Betriebssicherheit (Monitoring, Alerts, Telemetrie) ist mit Shell-Skripten nur begrenzt skalierbar.

## Entscheidung
- Migration zu einem langlaufenden Daemon mit folgenden Eigenschaften:
  1. **Persistente Queue** für neue Ereignisse (Datei oder leichtgewichtige DB), um Verluste bei Neustarts zu verhindern.
  2. **Retry- und Backoff-Strategie** für Pushes inkl. konfigurierbarer Rate-Limits pro Quelle.
  3. **Health/Status-Endpunkte** (HTTP) für Readiness/Liveness sowie Metriken (z. B. Anzahl offener Ereignisse, Alter).
  4. **Konfigurierbare Quellenadapter** (RSS, REST, manuelle Eingabe) mit gemeinsamer Normalisierung ans Schema.
  5. **Observability**: strukturierte Logs, optional Prometheus/Metrics-Endpunkt.
- Programmiersprache: Rust oder Python (Evaluation in Spike); Entscheidung fällt nach Prototyp bzgl. Wartbarkeit & Deployment.
- Übergangsphase: Skripte bleiben als Fallback bestehen, bis der Daemon Produktion erreicht.

## Konsequenzen
- Deutlich robusterer Betrieb mit automatischem Fehlerhandling, reduziertem manuellen Aufwand und besseren Einblicken.
- Höherer initialer Entwicklungsaufwand (Daemon, Tests, Deployment-Setup) und Bedarf an Build-/Runtime-Infrastruktur.
- CI/CD muss angepasst werden (Container-Build, Linting, Integrationstests gegen Leitstand-Staging).
- Schulung/Onboarding für Operator:innen bzgl. Monitoring und Deployment des Daemons.

## Umsetzungsfahrplan
1. **Spike**: Prototyp eines minimalen Daemons (Queue + Push) in Rust und Python, Evaluationsbericht.
2. **MVP**: Quellenadapter für bestehende Skript-Workflows, Persistenz über SQLite/Datei, einfache Retries.
3. **Betriebsfähigkeit**: Health-Endpunkte, Systemd-Unit, Logging-Standardisierung; Contract-Validation gegen `aussen.event.schema.json`.
4. **Erweiterungen**: Metrics, Konfigurationsoberfläche, automatisierte Schema-Validierung im Daemon.
5. **Ablösung**: Bash-Skripte deprekatieren, Dokumentation aktualisieren, Lessons Learned.

## Alternativen
- Bash-Skripte erweitern (verworfen: fehlende Testbarkeit, schwierige Parallelisierung).
- Externer Managed Service (verworfen: Datenschutz, Kosten, fehlende Kontrolle über Schema-Änderungen).
```

### 📄 docs/adr/README.md

**Größe:** 233 B | **md5:** `1df93fd0bc0ce6d90ffc87d84e4cca26`

```markdown
# Architekturentscheidungen (ADR)

## Übersicht
- [ADR-0001: Event-Format `aussen.event.schema.json` (kuratierter Feed)](0001-aussen-event-schema.md)
- [ADR-0002: MVP Bash+jq → kleiner Daemon (Rust/Python)](0002-mvp-to-daemon.md)
```
```

### 📄 merges/aussensensor_merge_2510262237__export.md

**Größe:** 397 B | **md5:** `71a49d6df2d787c29e4b48b6c24f0d63`

```markdown
### 📄 export/.gitkeep

**Größe:** 0 B | **md5:** `d41d8cd98f00b204e9800998ecf8427e`

```plaintext

```

### 📄 export/feed.jsonl

**Größe:** 176 B | **md5:** `50e188f30cd09e4b56c4ab4cf5b3ebcf`

```plaintext
{"ts":"2025-10-19T13:36:34+00:00","type":"news","source":"heise","title":"Testtitel","summary":"Kurztext","url":"https://example.org","tags":["urgent","topic:klima","Berlin"]}
```
```

### 📄 merges/aussensensor_merge_2510262237__index.md

**Größe:** 13 KB | **md5:** `bcbbf798843eaf911c012b1b640bb2da`

```markdown
# Ordner-Merge: aussensensor

**Zeitpunkt:** 2025-10-26 22:37
**Quelle:** `/home/alex/repos/aussensensor`
**Dateien (gefunden):** 23
**Gesamtgröße (roh):** 37 KB

**Exclude:** ['.gitignore']

## 📁 Struktur

- aussensensor/
  - .env.example
  - .gitignore
  - .hauski-reports
  - README.md
  - tests/
    - fixtures/
      - aussen/
        - .gitkeep
        - demo.jsonl
  - docs/
    - runbook.md
    - adr/
      - 0001-aussen-event-schema.md
      - 0002-mvp-to-daemon.md
      - README.md
  - .github/
    - workflows/
      - contracts-validate.yml
      - jsonl-guard.yml
      - push_leitstand.yml
      - validate-aussen-fixtures.yml
      - validate-feed.yml
      - validate.yml
  - .git/
    - FETCH_HEAD
    - HEAD
    - ORIG_HEAD
    - config
    - index
    - packed-refs
    - hooks/
      - pre-push
    - refs/
      - remotes/
        - origin/
          - HEAD
          - alert-autofix-1
          - alert-autofix-6
          - chore-code-review
          - docs-consistency-improvement
          - fix-dependency-checks
          - main
          - refactor-append-feed-script
          - refactor-validation-script
          - fix/
            - validation-logic
            - validation-tooling
          - codex/
            - add-ci-workflow-for-aussen-fixtures
            - add-heimlern-ingest-script-and-update-workflows
            - add-push_leitstand-script-and-workflow
            - add-runbook-and-jsonl-validation-workflow
            - add-validate-workflow-for-aussensensor
            - check-code-for-inconsistencies
            - check-documentation-completeness
            - find-errors-in-code
            - fix-check-jsonschema-pipe-in-append-feed.sh
            - fix-ci-workflow-file-not-found-error
            - fix-json-schema-validation-in-append-feed.sh
            - fix-stdin-validation-for-aussensensor
            - improve-validate.sh-for-robustness
            - locate-errors-in-code
            - locate-errors-in-the-code
            - push-aussen-sensor-to-leitstand
            - recreate-central-validation-script
            - refactor-append-feed.sh-for-usability
            - update-operational-documentation-and-gha-validator
          - feat/
            - improve-append-feed-script
      - tags/
      - heads/
        - main
        - backup/
          - main-20251017-182447
          - main-20251018-090525
          - main-20251021-124252
          - main-20251025-233736
    - logs/
      - HEAD
      - refs/
        - remotes/
          - origin/
            - HEAD
            - alert-autofix-1
            - alert-autofix-6
            - chore-code-review
            - docs-consistency-improvement
            - fix-dependency-checks
            - main
            - refactor-append-feed-script
            - refactor-validation-script
            - fix/
              - validation-logic
              - validation-tooling
            - codex/
              - add-ci-workflow-for-aussen-fixtures
              - add-heimlern-ingest-script-and-update-workflows
              - add-push_leitstand-script-and-workflow
              - add-runbook-and-jsonl-validation-workflow
              - add-validate-workflow-for-aussensensor
              - check-code-for-inconsistencies
              - check-documentation-completeness
              - find-errors-in-code
              - fix-check-jsonschema-pipe-in-append-feed.sh
              - fix-ci-workflow-file-not-found-error
              - fix-json-schema-validation-in-append-feed.sh
              - fix-stdin-validation-for-aussensensor
              - improve-validate.sh-for-robustness
              - locate-errors-in-code
              - locate-errors-in-the-code
              - push-aussen-sensor-to-leitstand
              - recreate-central-validation-script
              - refactor-append-feed.sh-for-usability
              - update-operational-documentation-and-gha-validator
            - feat/
              - improve-append-feed-script
        - heads/
          - main
          - backup/
            - main-20251017-182447
            - main-20251018-090525
            - main-20251021-124252
            - main-20251025-233736
    - objects/
      - de/
        - e2ec704d551ad5d55867f14c28b51f33b7d648
      - 6d/
        - 4f9d13bc490059559f0fcec5821105a1085ea7
        - 5370f23f89936316de0b2dd8f30ced7a89fb55
      - 0a/
        - b66a8e5c8433363fb1be9f7d1ccce184bed8d7
      - 06/
        - d958811ea0f33e707999b46a8b9b7f860891dc
      - d8/
        - e6a8a4d38e306c02499c6b3bc3cd2e7c9ba619
      - 87/
        - e841f2084e6fa48a6b8849db448dab698cb526
      - 7d/
        - 2f26fdb58215cc2d1be4ffb2c79785ce147a41
        - 96909d055eb855119f1878ca2c066666e1b189
        - c964e696ba976af6f366403de8ff342103a04d
      - 1d/
        - 6881f9bccf95b1a2e30b54950840c3ddf63690
      - 23/
        - 9e8589ae9c82566165f055cc5f897584223178
      - f3/
        - b8599f332a76d1e37a2c39256d5d2a5b0d1a39
      - 78/
        - 950a7c37fcb10515a40280e00f202f30f3765f
      - b9/
        - 34e1fac02c207b93ea5ed64d816d2b3456635a
      - e0/
        - 3f66d3661a716847d29084019ccd561aa04a3c
      - bc/
        - 21c2ed6a0fb813699516601617b49693ddc31c
      - 17/
        - 2dae2870fdec702ad108c197d6b52e2b6c06f3
      - a8/
        - 80ce0c65654b74b82567ee142be7971cfc0577
        - dfc3214311d34bd9be34b824fce3973ddb7e09
      - 38/
        - cec375c5ca7caf4022c41f1a4947680437db27
      - f9/
        - 83f1349f7cba9eaacbd8e01b4262d3b110aea8
      - 77/
        - 9726c854d24d29dfaa501d60511e00b70f94c7
      - 6a/
        - 5ed2bef4ea0732c605b3fb28413724ef635607
        - f2e810dd5797912667ffcfbe3c8d169e5b6c83
      - 4a/
        - 9e525b85f2f4fe7eb01af651b805a65f9caefd
        - c35e295803edd38e5bd1930a065790e215a469
      - 5a/
        - 57c1b2ad18b6adb31c3a6c27053abd43d56c15
      - b5/
        - 552af5da9b37857ce92997c7d65d86a207e036
      - d2/
        - c4da3fd66e1c29469b031150bfb6094ade4564
      - 9e/
        - 4bdfd1dfcfcd5b34c8c3dada73e24ada5bd4f0
      - dd/
        - 3e30be32447511a13cf070456c64184686f4db
      - 8d/
        - d35640241b495a238ed09f7650734fb8a7bdce
      - 26/
        - 91d2a60c3c1a0cff32b480cc4338631a6f3870
      - c6/
        - 56e05631581e170a8f3c03daab003303ba1820
      - pack/
        - pack-03a809fbea76558ef39817434fdb7099df41a4da.idx
        - pack-03a809fbea76558ef39817434fdb7099df41a4da.pack
        - pack-c11c92eede9778647da170a95e4e01f40231cda6.idx
        - pack-c11c92eede9778647da170a95e4e01f40231cda6.pack
      - f1/
        - 13ba482bb102541443b90304e5c3a929448786
        - 941330ef51501f6cf74e1fe21bc5f9cee3291a
        - e36d4991160cac0f7648c369479a843915124c
      - c3/
        - de0cfde31d713c8fd55c17d03316340d76271b
      - 66/
        - d17b5058e090c9df9807ee0407e73fc16a6c21
      - 92/
        - 92d510b4230cfc390f5945bab2e245a41e7a13
      - 94/
        - 9d936aad84a5d32dd9ed4e0dcdfdf332c83313
      - 7c/
        - 0eb98e78f6889f5305e26ff8e934fe8030e14e
      - e4/
        - 610b32c011476abc35b15c1462b53811af7a7a
      - d1/
        - aa8c847ee8923ef8bf6f106cfac72259ab661b
      - 4b/
        - db36eb192619ec1d6e02eddb1519f4cf308c04
      - 19/
        - 27a039edde9d89b84bf1df70f60008c5679f38
      - 64/
        - 1938139fd42bf028c6713d161ce3733e6782f8
        - 9a18056ec71d82210e627ca095e4907ed5c58a
      - c4/
        - 5078743d287148ac8519132a686f6098ad2af7
      - 8a/
        - a6a2bab1dc7869e5bcc80707d4a5c3a5551358
      - 7b/
        - 22f3e40c45f667c71fa70310f9f7f38d10df24
        - 71cbc1c241a4e8addba2a356944a40055c3022
      - e6/
        - 12450983d11b5ba403db90a06a0c63c5a2daab
        - 97d8a8e53d1e4bf1c1946433f145647b63ca68
      - 5b/
        - 3b95c2026a4f3f3e2f19cdc4690a6ac7d53ecc
      - 45/
        - 5eb00111d518d99d5b8ff063af1a9979468045
      - 90/
        - 9b5115525ffe3f750b0dd4b68a95db8bb0cdc5
      - f7/
        - d6c0a74ea9ea85978a0156d024e6d5ec4b611b
      - 28/
        - a3d950a781d93de522594da0561e8683e08db2
      - d9/
        - bfc511e250be0c4a63754da01799db8354c50c
      - 2b/
        - 6f2dc5a0bf4f11183ddacb131b2377ec08a350
      - 75/
        - 3de5b85702b62beaa01ff98eccd6117fe482e1
        - 6e5432207da5ccf960806a08f7af024fb08ef1
      - 63/
        - 659eda0be5312172f91ed96319e3022b0943bf
      - 8e/
        - e0fa860252f1ec1e59bd7a73737a68f47d3595
      - 27/
        - 773015e12617c948314ef832c43c8881a5faf9
      - 2a/
        - 844e27c81931410fb17c0bca9221bb9cd2aa4d
      - 3a/
        - ceaf5f1eddf6325904398f1c22ace9b6352b8a
      - 31/
        - 6a70ebd133dc5b0180902798f838710e268ad6
      - b3/
        - d6fba506ba3d3a645812547cf4295917c6d38a
      - a5/
        - 08751a45becdfe311533ed2979a40ccbbafc6f
        - 6e7ea91707ce4a4d753cdcad063aee673735b7
      - 1c/
        - 32d4533472fa8088e2d9f37213ad941ed393c0
      - 79/
        - 652696b26b25b69967a106d34f41c5d67aae66
      - 41/
        - 02f166f081585519bd21efffab7ced1f48a473
      - 39/
        - 243037d7e520e83f925cb100b0169b31fdfea9
      - 21/
        - 1d8537c1292089de2d99539437c0d90e7fb3f5
        - a2b6040b501985b7178d926ea3a0059fff0132
        - a93edf5c8759b78f40d009173d9278bcb9c248
      - 3d/
        - bc1271e9942df845563b22a4697758537cab52
      - 1a/
        - e7bf14cf7f308ccf675e86b78c15c74d388598
      - 99/
        - a2600d4232d08338d5f7588794e98b93689a64
      - 9d/
        - 119d274ede7978fb6eef96506e33d199bb911f
      - 25/
        - 2412e7fee262b8d2e3fec2108a79be6206425a
        - 91fd080cddf00fb7b1df1a26a16d58c6a40708
      - a9/
        - cbdded4ad0f27da9879a62f631bff3e03442fa
      - f4/
        - 4ba55459b0e895d982dbe77a372adcf3fc2141
      - 43/
        - 098f6284113fc8e71552dde02f7e6bc94fe922
        - 428ecd74bd1361239beb44679b87b83034457b
      - c1/
        - 1db6774719b5641677ca4857b70d58d2931ea5
      - 42/
        - 3c53af33100c97875be5201264ed2f62ec55c5
      - a7/
        - a63ba532ff2567caf219c7eae88e79c01648fd
      - 51/
        - f123529a8816f03ba8346ef0b65b693ac84074
      - 9f/
        - 3bf072e30a5acc0257fba8f387bd5e511fc3ab
      - 36/
        - b38948d80ed04fa84b8d8130974b032e562021
      - 93/
        - 70f68956b97a222c35d113460b08b89869d1c8
      - be/
        - 22ca2851ba1970ff2baae02be6ab80f51cf975
      - info/
      - 40/
        - 75e08997b8ab9699afe858249619cd7a27dc2f
        - a3061d2f898e1d4941026980ccd8723919ccdc
      - cf/
        - 38106c3c5876fc2ab64324cf127fe0bf1c7fbf
      - 22/
        - 51688d895d9feb09a60cf32ea6185d7ae62380
      - 34/
        - 5a3d378399bc3980ae76cc0ea26acc1c2f2ea2
      - 5c/
        - f493039cc8c18877d51b8cfcf7f0999f71c0d8
      - 7e/
        - 62d80a812ae2a1cd62b45f573780892678b67e
      - 5e/
        - 4e7e72e3a64b94c25bc11f2ed5453951dff9c9
  - merges/
    - aussensensor_merge_2510262237__index.md
  - export/
    - .gitkeep
    - feed.jsonl
  - scripts/
    - append-feed.sh
    - jsonl-compact.sh
    - push_heimlern.sh
    - push_leitstand.sh
    - validate.sh
  - contracts/
    - aussen.event.schema.json

## 📦 Inhalte (Chunks)

- .env.example → `aussensensor_merge_2510262237__root.md`
- .gitignore → `aussensensor_merge_2510262237__root.md`
- README.md → `aussensensor_merge_2510262237__root.md`
- tests/fixtures/aussen/.gitkeep → `aussensensor_merge_2510262237__tests_fixtures_aussen.md`
- tests/fixtures/aussen/demo.jsonl → `aussensensor_merge_2510262237__tests_fixtures_aussen.md`
- docs/runbook.md → `aussensensor_merge_2510262237__docs.md`
- docs/adr/0001-aussen-event-schema.md → `aussensensor_merge_2510262237__docs_adr.md`
- docs/adr/0002-mvp-to-daemon.md → `aussensensor_merge_2510262237__docs_adr.md`
- docs/adr/README.md → `aussensensor_merge_2510262237__docs_adr.md`
- .github/workflows/contracts-validate.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- .github/workflows/jsonl-guard.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- .github/workflows/push_leitstand.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- .github/workflows/validate-aussen-fixtures.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- .github/workflows/validate-feed.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- .github/workflows/validate.yml → `aussensensor_merge_2510262237__.github_workflows.md`
- export/.gitkeep → `aussensensor_merge_2510262237__export.md`
- export/feed.jsonl → `aussensensor_merge_2510262237__export.md`
- scripts/append-feed.sh → `aussensensor_merge_2510262237__scripts.md`
- scripts/jsonl-compact.sh → `aussensensor_merge_2510262237__scripts.md`
- scripts/push_heimlern.sh → `aussensensor_merge_2510262237__scripts.md`
- scripts/push_leitstand.sh → `aussensensor_merge_2510262237__scripts.md`
- scripts/validate.sh → `aussensensor_merge_2510262237__scripts.md`
- contracts/aussen.event.schema.json → `aussensensor_merge_2510262237__contracts.md`
```

### 📄 merges/aussensensor_merge_2510262237__part001.md

**Größe:** 43 B | **md5:** `ad150e6cdda3920dbef4d54c92745d83`

```markdown
<!-- chunk:1 created:2025-10-26 22:37 -->
```

### 📄 merges/aussensensor_merge_2510262237__root.md

**Größe:** 10 KB | **md5:** `1e632d4d5a1c2e3705f1cd0fd9560229`

```markdown
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
```

### 📄 merges/aussensensor_merge_2510262237__scripts.md

**Größe:** 12 KB | **md5:** `6c187fa05fe7f2f34914314656446086`

```markdown
### 📄 scripts/append-feed.sh

**Größe:** 5 KB | **md5:** `01bb562813ca26725a6dae1c355d9c56`

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Globale Variablen und Konstanten --------------------------------------

# Diese Variablen werden von parse_args gesetzt und von anderen Funktionen verwendet.
source=""
type=""
title=""
summary=""
url=""
declare -a pos_tags=()
opt_tags=""
tags_mode=""
OUTPUT_FILE=""

# Konstanten
SCRIPT_DIR=""
REPO_ROOT=""
SCHEMA_PATH=""


# --- Funktionen ------------------------------------------------------------

print_usage() {
  cat <<'USAGE' >&2
Usage:
  Positional:
    ./scripts/append-feed.sh <source> <type> <title> <summary> <url> [tags...]
      source   Menschlich lesbarer Bezeichner (z. B. heise, dwd)
      type     news|sensor|project|alert
      title    Titelzeile des Ereignisses
      summary  Kurzbeschreibung (max. 500 Zeichen)
      url      Referenz-Link
      tags     Optionale Liste einzelner Tags (einzelne Tokens, z. B. rss:demo klima)

  Optionen:
    -o file    Ausgabe-Datei (NDJSON). Standard: export/feed.jsonl
    -t type    Ereignistyp (news|sensor|project|alert). Standard: news
    -s source  Quelle (z. B. heise). Standard: manual
    -T title   Titel (erforderlich im Optionsmodus)
    -S summary Kurztext (optional, ≤ 500 Zeichen)
    -u url     Referenz-URL (optional)
    -g tags    Kommagetrennte Tags (z. B. "rss:demo, klima")
    -h         Hilfe anzeigen
USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

parse_args() {
  # Default-Werte setzen, bevor die Argumente verarbeitet werden.
  type="news"
  source="manual"
  title=""
  summary=""
  url=""
  opt_tags=""

  if [[ "${1:-}" != "-"* && "$#" -ge 5 ]]; then
    # Positionsmodus
    source="$1"; type="$2"; title="$3"; summary="$4"; url="$5"; shift 5
    mapfile -t pos_tags < <(printf '%s\n' "$@")
    tags_mode="positional"
  else
    # Optionsmodus (getopts)
    # OPTIND zurücksetzen, falls die Funktion mehrfach aufgerufen wird
    OPTIND=1
    while getopts ":ho:t:s:T:S:u:g:" opt; do
      case "$opt" in
        h) print_usage; exit 0 ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        t) type="$OPTARG" ;;
        s) source="$OPTARG" ;;
        T) title="$OPTARG" ;;
        S) summary="$OPTARG" ;;
        u) url="$OPTARG" ;;
        g) opt_tags="$OPTARG" ;;
        :) echo "Option -$OPTARG benötigt ein Argument." >&2; print_usage; exit 1 ;;
        \?) echo "Unbekannte Option: -$OPTARG" >&2; print_usage; exit 1 ;;
      esac
    done
    tags_mode="getopts"
  fi
}

validate_args() {
  if [[ -z "${source:-}" || -z "${type:-}" || -z "${title:-}" ]]; then
    echo "Fehler: source, type und title dürfen nicht leer sein." >&2
    print_usage
    exit 1
  fi

  case "$type" in
    news|sensor|project|alert) ;;
    *) echo "Fehler: type muss einer von {news|sensor|project|alert} sein." >&2; exit 1 ;;
  esac

  if [[ -n "${summary:-}" ]]; then
    # Zeichen zählen, ohne Leerzeichen aus dem Inhalt zu entfernen
    local summary_len
    summary_len="$(printf '%s' "$summary" | wc -m | xargs)"
    if (( summary_len > 500 )); then
      echo "Fehler: summary darf höchstens 500 Zeichen umfassen (aktuell $summary_len)." >&2
      exit 1
    fi
  fi
}

build_tags_json() {
  if [[ "${tags_mode:-}" == "positional" ]]; then
    if (( ${#pos_tags[@]} > 0 )); then
      printf '%s\n' "${pos_tags[@]}" | jq -R 'select(length > 0)' | jq -s .
    else
      echo '[]'
    fi
  else
    # getopts: Kommagetrennt -> Array
    jq -cn --arg tags "${opt_tags:-}" '
      if $tags == "" then []
      else
        $tags
        | split(",")
        | map(. | gsub("^\\s+|\\s+$"; ""))
        | map(select(. != ""))
      end'
  fi
}

build_json() {
  local tags_json
  tags_json=$(build_tags_json)
  local ts
  ts="$(date -Iseconds -u)"

  jq -cn \
    --arg ts "$ts" \
    --arg type "$type" \
    --arg source "$source" \
    --arg title "$title" \
    --arg summary "${summary:-}" \
    --arg url "${url:-}" \
    --argjson tags "$tags_json" \
    '{
      "ts": $ts,
      "type": $type,
      "source": $source,
      "title": $title,
      "summary": ($summary // ""),
      "url": ($url // ""),
      "tags": ($tags // [])
    }'
}

validate_json_schema() {
  local json_obj="$1"

  if ! printf '%s\n' "$json_obj" | "$SCRIPT_DIR/validate.sh"; then
    echo "Fehler: Das generierte Ereignis ist nicht valide." >&2
    echo "JSON-Objekt:" >&2
    echo "$json_obj" >&2
    exit 1
  fi
}

append_to_feed() {
  local json_obj="$1"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$json_obj" >> "$OUTPUT_FILE"
}

main() {
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"
  # Default output file, can be overwritten by -o flag
  OUTPUT_FILE="$REPO_ROOT/export/feed.jsonl"

  need date
  need jq
  need wc
  need xargs

  parse_args "$@"
  validate_args

  local json_obj
  json_obj=$(build_json)

  validate_json_schema "$json_obj"
  append_to_feed "$json_obj"

  echo "OK: Ereignis in '$OUTPUT_FILE' angehängt."
}

# --- Skriptausführung --------------------------------------------------------

# Führe main aus, es sei denn, das Skript wird nur "gesourced"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

### 📄 scripts/jsonl-compact.sh

**Größe:** 608 B | **md5:** `987a2552c0a5532b7e2da696dcc2989a`

```bash
#!/usr/bin/env bash
set -euo pipefail
#
# Kompaktifiziert *.jsonl: jede Zeile = valides, kompaktes JSON-Objekt.
# Nutzung:
#   scripts/jsonl-compact.sh export/feed.jsonl
#
file="${1:-}"
[[ -n "$file" && -f "$file" ]] || { echo "usage: $0 <file.jsonl>" >&2; exit 2; }

tmp="$(mktemp "${file##*/}.XXXX")"
trap 'rm -f "$tmp"' EXIT

# Zeilenweise lesen, in kompaktes JSON (-c) konvertieren; invalide Zeilen brechen ab.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "${line// }" ]] || continue
  printf '%s\n' "$line" | jq -e -c . >>"$tmp"
done <"$file"

mv -f -- "$tmp" "$file"
echo "compacted: $file"
```

### 📄 scripts/push_heimlern.sh

**Größe:** 288 B | **md5:** `122ecddd60620babc32c37d75ecc2971`

```bash
#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-export/feed.jsonl}"
[[ -f "$FILE" ]] || { echo "missing $FILE"; exit 1; }
: "${HEIMLERN_INGEST_URL:?set HEIMLERN_INGEST_URL}"
curl -sS -X POST "$HEIMLERN_INGEST_URL" \
  -H "Content-Type: application/jsonl" \
  --data-binary @"$FILE"
echo
```

### 📄 scripts/push_leitstand.sh

**Größe:** 3 KB | **md5:** `31b4321770333a458d48fa98fd28c2ae`

```bash
#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: scripts/push_leitstand.sh [options]

Options:
  -f, --file PATH        Pfad zur JSONL-Datei (Standard: export/feed.jsonl)
      --url URL          Ziel-Endpoint (überschreibt $LEITSTAND_INGEST_URL)
      --token TOKEN      Authentifizierungs-Token (überschreibt $LEITSTAND_TOKEN)
      --content-type CT  Content-Type Header (Standard: $CONTENT_TYPE oder application/x-ndjson)
      --dry-run          Keine Übertragung, sondern nur Anzeige der Aktion
  -h, --help             Diese Hilfe anzeigen
USAGE
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FILE_PATH="$REPO_ROOT/export/feed.jsonl"
INGEST_URL="${LEITSTAND_INGEST_URL:-}"
AUTH_TOKEN="${LEITSTAND_TOKEN:-}"
CONTENT_TYPE="${CONTENT_TYPE:-application/x-ndjson}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für $1" >&2; exit 1; }
      FILE_PATH="$2"
      shift 2
      ;;
    --url)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --url" >&2; exit 1; }
      INGEST_URL="$2"
      shift 2
      ;;
    --token)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --token" >&2; exit 1; }
      AUTH_TOKEN="$2"
      shift 2
      ;;
    --content-type)
      [[ $# -ge 2 ]] || { echo "Fehlender Parameter für --content-type" >&2; exit 1; }
      CONTENT_TYPE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $1" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INGEST_URL" ]]; then
  echo "Fehler: LEITSTAND_INGEST_URL ist nicht gesetzt und --url wurde nicht übergeben." >&2
  exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
  echo "Fehler: Datei '$FILE_PATH' nicht gefunden." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Fehlt: curl" >&2
  exit 1
fi

event_count=0
if [[ -f "$FILE_PATH" ]]; then
  event_count="$(grep -cve '^\s*$' "$FILE_PATH" 2>/dev/null || echo 0)"
fi

if [[ ! -s "$FILE_PATH" ]]; then
  echo "Warnung: Datei '$FILE_PATH' ist leer." >&2
fi

if [[ -z "${CONTENT_TYPE//[[:space:]]/}" ]]; then
  echo "Fehler: Content-Type ist leer." >&2
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY-RUN] Würde $event_count Ereignis(se) an '$INGEST_URL' übertragen." >&2
  echo "[DRY-RUN] Datei: $FILE_PATH" >&2
  if [[ -n "$AUTH_TOKEN" ]]; then
    echo "[DRY-RUN] Token: gesetzt (${#AUTH_TOKEN} Zeichen)." >&2
  else
    echo "[DRY-RUN] Token: nicht gesetzt." >&2
  fi
  echo "[DRY-RUN] Content-Type: $CONTENT_TYPE" >&2
  if [[ -f "$FILE_PATH" ]]; then
    head -n5 "$FILE_PATH" >&2 || true
  fi
  exit 0
fi

curl_args=(
  --fail
  --silent
  --show-error
  --request POST
  --header "Content-Type: $CONTENT_TYPE"
  --data-binary "@$FILE_PATH"
)

if [[ -n "$AUTH_TOKEN" ]]; then
  curl_args+=(--header "x-auth: $AUTH_TOKEN")
fi

curl "${curl_args[@]}" "$INGEST_URL"
printf '\nOK: Feed an %s gesendet.\n' "$INGEST_URL" >&2
```

### 📄 scripts/validate.sh

**Größe:** 2 KB | **md5:** `ce2269db1f2a9cf406cc5ad60f0e93a2`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_PATH="$REPO_ROOT/contracts/aussen.event.schema.json"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Fehlt: $1" >&2; exit 1; }
}

print_usage() {
  cat <<'USAGE' >&2
Usage:
  ./scripts/validate.sh [file.jsonl]
    Validiert jede Zeile der angegebenen Datei.

  <json-producer> | ./scripts/validate.sh
    Validiert das JSON-Objekt von stdin.
USAGE
}

# --- Main --------------------------------------------------------------------

need npx

# Temporäre Datei für die Validierung erstellen und Bereinigung sicherstellen
TMP_EVENT_FILE="$(mktemp /tmp/aussen_event.XXXX.json)"
trap 'rm -f "$TMP_EVENT_FILE"' EXIT

validate_line() {
  local line="$1"
  local context="$2"

  # Leere Zeilen ignorieren
  [[ -z "${line// }" ]] && return 0

  printf '%s\n' "$line" > "$TMP_EVENT_FILE"

  if ! npx -y ajv-cli@5 validate \
    --spec=draft2020 \
    --strict=false \
    --validate-formats=false \
    -s "$SCHEMA_PATH" \
    -d "$TMP_EVENT_FILE" >/dev/null; then
    echo "Fehler: Validierung fehlgeschlagen ($context)." >&2
    # Zeige die ausführliche Fehlermeldung von ajv
    npx -y ajv-cli@5 validate \
      --spec=draft2020 \
      --strict=false \
      --validate-formats=false \
      -s "$SCHEMA_PATH" \
      -d "$TMP_EVENT_FILE"
    exit 1
  fi
}

if [[ $# -gt 0 && -f "$1" ]]; then
  # Datei-Modus
  FILE_TO_CHECK="$1"
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "Zeile $line_num in '$FILE_TO_CHECK'"
  done < "$FILE_TO_CHECK"
  echo "OK: Alle Zeilen in '$FILE_TO_CHECK' sind valide."

elif [[ $# -eq 0 && ! -t 0 ]]; then
  # Stdin-Modus
  line_num=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_num=$((line_num + 1))
    validate_line "$line" "stdin (Zeile $line_num)"
  done
  echo "OK: Stdin-Daten sind valide."
else
  print_usage
  exit 1
fi
```
```

### 📄 merges/aussensensor_merge_2510262237__tests_fixtures_aussen.md

**Größe:** 369 B | **md5:** `04af08b8bd403f448693752aa4a25ca2`

```markdown
### 📄 tests/fixtures/aussen/.gitkeep

**Größe:** 0 B | **md5:** `d41d8cd98f00b204e9800998ecf8427e`

```plaintext

```

### 📄 tests/fixtures/aussen/demo.jsonl

**Größe:** 118 B | **md5:** `a42379b2989feb302b475717cfc02597`

```plaintext
{"ts":"2025-01-01T00:00:00Z","type":"news","source":"fixture","title":"Demo Fixture","summary":"","url":"","tags":[]}
```
```

