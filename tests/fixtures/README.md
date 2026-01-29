# Test Fixtures

Dieses Verzeichnis enthält Testdaten für verschiedene Validierungsszenarien.

## Struktur

* **`aussen/`**: Enthält gültige und ungültige Beispiele für das **Haupt-Vertragsschema** (`contracts/aussen.event.schema.json`).
  * Diese Dateien werden von der CI (`fixtures-validate.yml`) automatisch gegen den Contract validiert.

* **`ref-resolution/`**: Enthält isolierte Testdaten für Unit-Tests der Validierungslogik (z.B. `$ref`-Auflösung).
  * Diese Dateien nutzen eigene, lokale Schemas und sind **nicht** kompatibel mit dem Haupt-Contract.
  * Sie werden **nicht** vom allgemeinen Fixture-Validator geprüft, sondern explizit durch BATS-Tests (z.B. `tests/test_validate_ref.bats`).
