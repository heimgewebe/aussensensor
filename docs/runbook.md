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
   export CHRONIK_INGEST_URL="https://chronik.example/ingest/aussen"
   ./scripts/push_chronik.sh --dry-run   # zum Testen
   ./scripts/push_chronik.sh             # produktiver Push
   ```
   - Token via `CHRONIK_TOKEN` setzen oder Flag `--token` nutzen.
   - Dry-Run prüfen, danach echten Push ausführen.
   - Hinweis: Das `leitstand`-Repo ist künftig das UI/Dashboard.

## Änderungsfreeze / Freeze-Prozedur
Wenn der Feed eingefroren werden muss (z. B. vor einem Incident-Review oder wegen ungeklärter Validierungsfehler):
1. **Kommunizieren**
   - Im Teamkanal (z. B. `#chronik-feed`) Freeze ankündigen und Grund nennen.
   - Issue oder Incident-Notiz im Repository anlegen.
2. **Freeze markieren**
   - Branch `freeze/<datum>-<kurzgrund>` erstellen.
   - Datei `export/feed.jsonl` in `main` nicht mehr verändern.
   - Optional: GitHub Environment "freeze" nutzen (falls vorhanden) und Deployment blockieren.
3. **CI überwachen**
   - `validate (aussensor feed)` muss zuletzt grün gelaufen sein; bei roten Läufen *kein* Push an die Chronik.
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
- Chronik mit aktuellem Feed versorgt (falls notwendig)?
- Offene Incidents oder Freeze-Status dokumentiert?
