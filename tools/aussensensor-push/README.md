# aussensensor-push

Ein leichtgewichtiges Rust-CLI-Tool zum Übertragen von NDJSON-Ereignissen an die Chronik-Ingest-API.

## Zweck

`aussensensor-push` ist ein optionales Hilfsprogramm, das von den Bash-Skripten `push_chronik.sh` und `push_heimlern.sh` automatisch verwendet wird, falls es installiert ist. Es bietet:

- Robuste NDJSON-Verarbeitung
- Korrekte Content-Type-Header (`application/x-ndjson`)
- Authentifizierung via `x-auth` Header
- Dry-Run-Modus für Testläufe

## Installation

### Voraussetzungen

- Rust Toolchain (rustc ≥ 1.70)
- Cargo (wird mit Rust installiert)

### Build & Installation

```bash
cd tools/aussensensor-push
cargo build --release
sudo install -m 0755 target/release/aussensensor-push /usr/local/bin/
```

### Verifizierung

```bash
aussensensor-push --help
```

## Verwendung

```bash
aussensensor-push \
  --url "https://chronik.example/v1/ingest" \
  --file export/feed.jsonl \
  --token "your-auth-token" \
  --dry-run  # optional: nur Testlauf
```

### Argumente

- `--url`: Ziel-Endpoint (vollständige URL inkl. `/v1/ingest`)
- `--file`: Pfad zur JSONL-Datei mit Ereignissen
- `--token`: Authentifizierungstoken (optional)
- `--dry-run`: Testlauf ohne tatsächliche Übertragung

## Integration

Die Bash-Skripte erkennen automatisch, ob `aussensensor-push` verfügbar ist:

```bash
if command -v aussensensor-push >/dev/null 2>&1; then
  # Nutze aussensensor-push
else
  # Fallback auf curl
fi
```

Falls das Binary nicht installiert ist, greifen die Skripte auf `curl` zurück.

## Entwicklung

### Tests

```bash
cargo test
```

### Linting

```bash
cargo clippy -- -D warnings
```

## Lizenz

MIT OR Apache-2.0
