# External Evidence Collector

## Zweck

Aussensensor ist die kontrollierte Wahrnehmungsgrenze zwischen veränderlichen externen Tatsachen und dem Heimgewebe. Er soll nicht möglichst viel Internet sammeln, sondern wenige externe Annahmen beobachten, deren Änderung reale Operator-Entscheidungen beeinflusst.

Der Vertrag lautet:

`externe Quelle -> begrenzte Beobachtung -> aussen.event -> Chronik`

Aussensensor besitzt dabei weder Task-Autorität noch Policy-Autorität. Er erzeugt Evidenz. Chronik besitzt die historische Ablage; Bureau entscheidet über Arbeit; Grabowski führt autorisierte Arbeit aus.

## Was dadurch konkret möglich wird

- Verschwundene oder wieder verfügbare Coding-Modelle erkennen, bevor ein Agentenpfad überraschend scheitert.
- Externe Dienststörungen von internen Fehlern unterscheiden, z. B. bei GitHub.
- Änderungen an API-Katalogen, Releases oder Security-Advisories als zeitgebundene, quellgebundene Ereignisse festhalten.
- Später Vibe-Lab oder andere Auswertungen mit historischer Evidenz versorgen, ohne den Sensor selbst entscheiden zu lassen.

Das Ziel ist weniger Blindflug, nicht mehr Alarmrauschen.

## Implementierter V1-Pfad

`scripts/collect_external.py` liest ausschließlich explizit konfigurierte HTTPS-JSON-Quellen. Unterstützt werden zwei kleine Adapter:

- `json-set`: beobachtet eine Menge stabiler Identitäten und meldet relevante Hinzufügungen, Entfernungen sowie erwartete fehlende oder wiederhergestellte Werte.
- `json-value`: beobachtet einen einzelnen JSON-Wert und meldet Änderungen oder Abweichungen von einem erwarteten Wert.

Die Standardkonfiguration `config/external-sources.json` beobachtet derzeit:

1. den öffentlichen OpenRouter-Modellkatalog; `stealth/ox-alpha` ist als aktuell erwartete Operator-Abhängigkeit eingetragen;
2. den öffentlichen GitHub-Status; `status.indicator == "none"` gilt als Normalzustand.

`expected_items` und `expected_value` sind ausdrücklich **lokale Operator-Annahmen**, keine Wahrheit über den Anbieter. Wenn eine Abhängigkeit absichtlich aufgegeben wird, muss die Erwartung aus der Konfiguration entfernt werden.

## Sicherheitsgrenzen

- nur HTTPS;
- nur HTTPS-Standardport 443;
- Host muss in `allowed_hosts` stehen;
- keine Credentials in URLs;
- localhost, `.local` und nicht öffentliche DNS-Ziele werden abgewiesen;
- Redirect-Ziele werden erneut gegen Scheme und Host-Allowlist geprüft;
- Antwortgröße und Timeout sind begrenzt;
- JSON muss syntaktisch gültig sein;
- Quellen werden vor einer State-Fortschreibung vollständig gelesen;
- produktive Collect-and-Push-Läufe benötigen einen exklusiven `flock` auf dem Vergleichs-State;
- Chronik-Zustellung gilt nur bei einem direkten 2xx; Redirects werden nicht als Erfolg akzeptiert;
- der Collector crawlt keine Links und führt keine Quelle als Code aus.

Die DNS-Prüfung reduziert SSRF-Risiken, ist aber kein vollständiger Schutz gegen DNS-Rebinding. Der primäre Schutz bleibt die kleine explizite Host-Allowlist.

## Ereignisse und Provenienz

Jedes erzeugte `aussen.event` enthält unter anderem:

- stabile, deterministische Event-ID;
- Quellbezeichner und Quell-URL;
- Beobachtungszeitpunkt;
- Change-Klasse und Schweregrad;
- SHA-256 der tatsächlich gelesenen HTTP-Antwort;
- Adapter- und Source-ID.
Der V1 speichert die Rohantwort selbst nicht dauerhaft. Der SHA-256 bindet das Ereignis an die damals gelesenen Bytes und hilft bei Korrelation und Deduplizierung, ist aber allein kein später selbstgenügsam verifizierbares Rohbeweisarchiv. Eine dauerhafte Raw-Snapshot-Retention ist deshalb bewusst kein impliziter Bestandteil dieses V1.


Die Event-ID hängt nicht vom aktuellen Retry-Pollzeitpunkt ab. Sie bindet den semantischen Übergang an den zuletzt erfolgreich gespeicherten Beobachtungszustand: Wiederholungen desselben unzugestellten Befunds bleiben deduplizierbar, ein späterer neuer Vorfall nach zwischenzeitlicher Erholung erhält dagegen eine neue ID.

## Einzellauf

```bash
python3 scripts/collect_external.py \
  --config config/external-sources.json \
  --state .state/external-evidence.json \
  --output export/external-evidence.jsonl
```

Bei einem reinen Collector-Lauf wird der Vergleichs-State nach erfolgreicher Beobachtung fortgeschrieben. Für den produktiven Versand ist deshalb der transaktionale Wrapper vorzuziehen.

## Collect -> Validate -> Chronik

```bash
scripts/collect-and-push.sh
```

Der Wrapper arbeitet fail-closed:

1. externe Quellen beobachten;
2. neuen State zunächst nur als Kandidaten schreiben;
3. bei relevanter Änderung NDJSON gegen den kanonischen Contract validieren;
4. Ereignisse an Chronik senden;
5. erst nach erfolgreichem Delivery-Pfad den Vergleichs-State fortschreiben.

Scheitert Validierung oder Chronik-Push, bleibt der alte State erhalten. Der Befund wird beim nächsten Lauf erneut erzeugt, statt still verloren zu gehen.

Für einen wirkungsfreien Test:

```bash
AUSSENSENSOR_DRY_RUN=1 scripts/collect-and-push.sh
```

Im Dry-Run wird der Vergleichs-State nicht fortgeschrieben.

## Aufnahme neuer Quellen

Eine Quelle sollte nur aufgenommen werden, wenn alle Punkte erfüllt sind:

1. **Operator-Relevanz:** Eine Änderung kann eine reale Entscheidung, Verfügbarkeit, Sicherheit oder Diagnose beeinflussen.
2. **Primärnähe:** Nach Möglichkeit Anbieter-API, offizieller Status oder offizielles Advisory statt Aggregator.
3. **Maschinenlesbarkeit:** stabile JSON-Struktur oder ein eigener eng begrenzter Adapter.
4. **Änderungssemantik:** vorab definierbar, was relevant und was Rauschen ist.
5. **Sicherer Abruf:** HTTPS und explizit zulässiger Host.
6. **Downstream-Nutzen:** Das Ereignis ist in Chronik später tatsächlich auswertbar.

Nicht aufnehmen: allgemeine Newsfeeds nur „weil sie existieren“, unklare Scraper, beliebige benutzerkontrollierte URLs oder Signale ohne absehbare Folge.

## Sinnvolle nächste Sensorfamilien

Priorität A:

- Coding-/LLM-Provider: Modellkataloge, offizielle Statusseiten, Deprecations und öffentlich belegbare Verfügbarkeitsänderungen;
- GitHub: Status wichtiger Dienste;
- Security: offizielle Advisories, wenn sie Komponenten des Operator-Stacks betreffen.

Priorität B:

- Kernel-, Treiber- und Paket-Releases, soweit sie für tatsächlich eingesetzte Systeme relevant sind;
- externe API-Versionen oder Deprecations, von denen produktive Heimgewebe-Pfade abhängen.

Priorität C:

- Wetter- oder Warnlagen, wenn ein konkreter Heim-/Operator-Use-Case sie konsumiert.

Weitere Quellen werden nicht allein zur Abdeckung hinzugefügt. Aussensensor ist dann erfolgreich, wenn er wenige wichtige externe Änderungen früher und verlässlicher sichtbar macht als der bisherige manuelle Zufall.
