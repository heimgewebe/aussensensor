# Evaluation des Repos aussensensor

## Überblick

Das Repository `aussensensor` dient als Kurations‑Layer für externe Informationsquellen (Newsfeeds, Sensor‑Daten, Projektmeldungen). Der aktuelle MVP wird durch Bash‑Skripte realisiert, die Ereignisse im NDJSON‑Format erzeugen, validieren und an die Chronik/Heimlern‑Schnittstellen pushen. Das zentrale Ereignisformat ist in einem JSON‑Schema definiert (`contracts/aussen.event.schema.json`), und die Aufgaben werden durch einzelne Shell‑Skripte abgebildet: Appendieren, Validieren, Kompaktifizieren und Pushen. Außerdem existiert ein optionales Rust‑CLI (`aussensensor‑push`) für den effizienten NDJSON‑Upload sowie eine wgx‑Konfiguration zur Vereinfachung von Guard‑ und Build‑Tasks. GitHub‑Actions‑Workflows übernehmen Shell‑Linting, Testausführung (`bats-core`), JSONL‑Validierung und das Deployment an die Chronik.

### Stärken

*   **Klarer Contract und Datenqualität** – Das Repository definiert ein striktes Ereignisschema. Pflichtfelder wie `ts`, `type`, `source` und `title` werden erzwungen; zusätzliche Felder sind nicht erlaubt, was Downstream‑Services vereinfacht. Tags werden dedupliziert und als Array geschrieben; `append-feed.sh` setzt fehlende Werte (z. B. `ts`) automatisch.
*   **Gute Basistests und CI** – Shell‑Skripte werden mit `shellcheck` geprüft, und es existieren einige Bats‑Tests für `append-feed.sh`. GitHub‑Actions validieren jede Zeile des Feeds mit AJV und führen Tests automatisch aus.
*   **Zukunftsvision** – In der Roadmap ist eine Migration zu einem Daemon mit persistenter Queue und Retry‑Mechanismus vorgesehen. Die ADR‑Dokumente beschreiben diese Entscheidung sowie das Event‑Format und geben Kontext zu den Beweggründen.
*   **Rust‑Client für Uploads** – Das kleine Rust‑Tool `aussensensor‑push` sorgt für effizienten NDJSON‑Upload und kann alternativ zu `curl` genutzt werden.

Diese solide Basis bildet eine gute Grundlage, lässt aber noch Raum für Verbesserungen hinsichtlich Code‑Organisation, Testabdeckung, Automatisierung und künftiger Architektur.

## Schwachstellen & Verbesserungspotential

### Begrenzte Testabdeckung und Fehlertests

Die aktuellen Bats‑Tests decken vor allem die CLI‑Argumente von `append-feed.sh` ab. Es fehlen Tests für Randfälle wie gleichzeitiges Anhängen (`flock`/Lock‑Verhalten), die integrative Nutzung der Push‑Skripte, das Verhalten bei ungültigen oder leer gelassenen Feldern und Fehlerszenarien beim HTTP‑Upload. Auch die Validierungs‑Skripte und das Rust‑Binary werden kaum getestet.

### Komplexität in Bash‑Skripten

Die Bash‑Skripte sind recht umfangreich: `append-feed.sh` implementiert Argument‑Parsing, Tag‑Handling, JSON‑Erzeugung via `jq`, Schema‑Validierung, Locking und Datei‑I/O in einem. Dies erhöht die Fehleranfälligkeit und erschwert das Testen. Zudem wird JSON‑Schema‑Validierung über `jq` und AJV (via Node) „on the fly“ umgesetzt; bei großen Feeds kann die Performance leiden. Ein Teil der Logik (z. B. Validierung und JSON‑Erzeugung) ließe sich besser in eine höhere Programmiersprache auslagern.

### Künftige Skalierung / Daemonisierung

Laut ADR‑0002 ist eine Migration zu einem langlaufenden Daemon geplant. Doch die jetzige Code‑Basis ist stark um Skripte herum aufgebaut. Eine schrittweise Entkopplung der Kernlogik (Event‑Erzeugung, Validierung, Persistenz) von der Shell wäre sinnvoll, um sie im Daemon wiederzuverwenden. Außerdem fehlen derzeit persistente Queues, Retry‑Mechanismen und Metriken; Push‑Skripte senden den kompletten Feed in einem Stück, was bei wachsenden Datenmengen problematisch ist.

### Dokumentation & Developer‑Erfahrung

Die Dokumentation ist ausführlich, aber ausschließlich deutschsprachig. Für eine mögliche Zusammenarbeit mit internationalen Entwicklern wäre eine englische Version hilfreich. Es fehlen außerdem Beispiele für Fixture‑Dateien und eine schnelle Möglichkeit, das Projekt lokal in einem Container oder über Docker auszuführen. Die `wgx`‑Konfiguration deckt einige Aufgaben ab, aber ein Standard‑Makefile oder `justfile` könnte Entwickler schneller durch die gängigen Aufgaben führen.

## Konkrete Optimierungsvorschläge

### 1 – Refactoring & Modularisierung

*   **Aufteilen der Bash‑Skripte**: Die Logik in `append-feed.sh` lässt sich in kleinere Hilfsskripte oder Funktionen zerlegen, z. B. separates Modul für Argument‑Parsing, Tag‑Verarbeitung und Locking. Alternativ könnte diese Funktionalität in Python oder Go portiert werden, um Tests und Wartbarkeit zu verbessern.
*   **Wiederverwendbare Bibliothek für Events**: Implementieren Sie eine kleine Bibliothek (z. B. in Rust oder Python), die das Erzeugen, Validieren und Serialisieren von Events übernimmt. Sowohl die CLI‑Tools als auch der künftige Daemon können darauf aufbauen. Dadurch wird die Kernlogik unabhängig vom Ausführungsumfeld.
*   **Striktere Typsicherheit**: In Bash ist die Typkontrolle begrenzt. Für mission‑kritische Aufgaben (JSON‑Parsing, HTTP‑Requests) bietet eine typsichere Sprache Vorteile. Das Rust‑Programm `aussensensor‑push` könnte erweitert werden, um auch das Appendieren und Validieren zu übernehmen.

### 2 – Ausbau der Testabdeckung

*   **Tests für Push‑Skripte und Rust‑Binary**: Schreiben Sie Bats‑Tests, die erfolgreiche und fehlerhafte Uploads simulieren (z. B. mit einem lokalen `nc`‑Server). Testen Sie Dry‑Run‑Pfad, Fehlertypen und Header‑Verarbeitung.
*   **Locking und Concurrency**: Erstellen Sie Tests, die parallele Aufrufe von `append-feed.sh` ausführen, um das Locking zu prüfen (z. B. mit Hintergrundprozessen). Testen Sie den Fallback‑Lock ohne `flock`.
*   **Schema‑Validierung**: Erweitern Sie die Tests so, dass ungültige Events (fehlende Pflichtfelder, falscher Typ, zu lange Summary) erkannt werden. Die aktuelle Implementierung prüft nur, dass eine zu lange Summary (>2000 Zeichen) abgelehnt wird; hier sollten auch Extremfälle wie fehlende Tags, `type=="link"` ohne URL usw. getestet werden.

### 3 – CI/CD‑Verbesserungen

*   **Caching von Abhängigkeiten**: Node‑Module (`ajv`) und Rust‑Dependencies können in GitHub‑Actions gecacht werden, um Build‑Zeiten zu reduzieren. Bei größeren Tests kann ein Matrix‑Build für unterschiedliche Umgebungen eingerichtet werden.
*   **Integration von Code‑Quality‑Checks**: Neben `shellcheck` könnten Linter wie `shfmt` (für Formatierung) und `clippy`/`cargo fmt` für das Rust‑Projekt integriert werden. Die `wgx-guard`‑Aufgabe validiert aktuell nur das Feed‐File; hier könnten auch YAML‑Linting und JSON‑Schema‑Linting eingebunden werden.
*   **Release‑Automation**: Richten Sie GitHub‑Releases oder Tags ein, um stabile Versionen der Contracts und des Rust‑Binaries zu veröffentlichen. Das erhöht Nachvollziehbarkeit und erleichtert die Nutzung als Abhängigkeit.

### 4 – Architektur & Daemonisierung

*   **Prototyp des Daemons**: Im Sinne der ADR‑0002 sollte ein Prototyp in einer höherstufigen Sprache entwickelt werden (Rust oder Python). Er könnte folgende Kernfunktionen bieten: Eingehende Events über verschiedene Adapter (RSS‑Feeds, REST‑APIs, manuelle Einträge), Validierung gegen das Schema, persistente Queue (z. B. SQLite oder simples Dateiformat) und periodische Pushes. Retry‑Mechanismen, Backoff‑Strategien und Health‑Endpunkte können danach ergänzt werden.
*   **Streaming‑Push statt Bulk**: Anstatt den gesamten Feed zu übertragen, könnte der Daemon Events einzeln oder in Batches streamen. Dies reduziert Speicherverbrauch und vereinfacht das Fehlerhandling. Auch `aussensensor‑push` könnte in Zukunft Streaming unterstützen.
*   **Observability**: Definieren Sie Metriken wie „Anzahl Events in Queue“, „Alter des ältesten Events“, „Push‑Erfolgsrate“. Exponieren Sie sie per Prometheus‑Endpoint und verarbeiten Sie Logs strukturiert (JSON‑Logformat). Die Roadmap sieht Telemetrie ausdrücklich vor.

### 5 – Verbesserung des Contracts & Datenqualität

*   **Eindeutige IDs**: Im Schema existiert bereits ein optionales Feld `id`. Für Datenkonsumenten ist eine stabile ID hilfreich, um Duplikate zu erkennen. Erwägen Sie, dieses Feld zu generieren (z. B. via SHA‑256 der relevanten Felder) und optional zum Pflichtfeld zu machen. Das könnte in `append-feed.sh` bzw. in der neuen Bibliothek erfolgen.
*   **Felder `features` und `meta`**: Diese Felder erlauben beliebige Objekte. Definieren Sie ein internes Format oder Versionierung, um spätere Auswertungen zu erleichtern. Außerdem sollten die Skripte optionale Felder wie `url` und `summary` nur dann schreiben, wenn sie vorhanden sind, um leere Strings zu vermeiden; das reduziert Datenvolumen.
*   **Schema‑Versionierung**: Der README verweist auf das Contracts‑Repo als Quelle der Wahrheit. Es wäre sinnvoll, die verwendete Schema‑Version in `export/feed.jsonl` oder in Git‑Tags zu vermerken, damit bei Schema‑Updates Migrationen nachvollziehbar bleiben.

### 6 – Developer Experience & Dokumentation

*   **Zweistufige Dokumentation**: Ergänzen Sie die deutsche Dokumentation um eine englische Version (`README_EN.md`). Internationale Teammitglieder können so schneller beitragen.
*   **Beispiele & Fixtures**: Fügen Sie im Ordner `tests/fixtures/aussen/` mehr realistische Beispiel‑Events hinzu und beschreiben Sie diese im Runbook. Entwickler können dann schneller validieren und verstehen, wie verschiedene Quellen abgebildet werden.
*   **Containerisierte Umgebung**: Ein Dockerfile oder eine `devcontainer.json` hilft, die erforderlichen Tools (`bash`, `jq`, `node`, Rust) einheitlich zur Verfügung zu stellen. Dadurch entfällt die manuelle Installation und das Onboarding wird beschleunigt.
*   **Kommandoübersicht**: Neben dem `wgx`‑Profil könnte ein Makefile oder `justfile` eine einheitliche Oberfläche bieten (z. B. `make test`, `make validate`, `make push`). Das verringert die Einstiegshürde und macht Abläufe reproduzierbar.

## Fazit

Das Projekt `aussensensor` stellt eine gut strukturierte Sammlung von Tools zur Verfügung, um externe Informationen in ein einheitliches Format zu überführen. Die Kernideen – strenges Ereignisschema, unkomplizierte Shell‑Werkzeuge, klare Roadmap zur Daemonisierung – sind überzeugend. Durch eine bessere Modularisierung (idealerweise in einer typsicheren Sprache), erweiterte Tests und Verbesserungen in der CI/CD‑Pipeline lässt sich die Qualität weiter steigern. Die kommende Migration zu einem Daemon eröffnet zudem Chancen, Persistenz, Retry‑Logik und Observability zu integrieren. Wenn diese Optimierungen umgesetzt werden, kann `aussensensor` als robuste, skalierbare Komponente innerhalb des Heimgewebe‑Organismus dienen.
