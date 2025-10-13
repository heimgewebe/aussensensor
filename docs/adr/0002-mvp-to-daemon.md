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
