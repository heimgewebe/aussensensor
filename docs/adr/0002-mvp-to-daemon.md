# ADR-0002: MVP Bash+jq → kleiner Daemon (Rust/Python)
Status: Accepted
Date: 2025-10-12

## Kontext
Dauerbetrieb, mehrere Quellen, Rate-Limits, Backoff.

## Entscheidung
- Roadmap: auf Daemon migrieren (Retry, Dedup, Health, Tests).

## Konsequenzen
- Stabiler Betrieb; bessere Telemetrie.

## Alternativen
- Bash dauerhaft: fragil.
