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

