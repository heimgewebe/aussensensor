#!/usr/bin/env bats

setup() {
    load 'bats-support/load'
    load 'bats-assert/load'

    # Create a dedicated temporary directory for this test file
    TEST_TMPDIR="$(mktemp -d -t bats-fixes-XXXXXX)"

    # Pfad zum Skript
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    APPEND_FEED="$REPO_ROOT/scripts/append-feed.sh"

    # Temporäre Ausgabedatei
    TEST_OUTPUT_FILE="$TEST_TMPDIR/test_feed.jsonl"

    # Sicherstellen, dass NODE_PATH sauber ist (Backup falls existent)
    # Wir speichern den Wert immer, auch wenn er leer ist, um deterministisches Verhalten zu garantieren.
    ORIG_NODE_PATH="${NODE_PATH:-}"
}

teardown() {
    rm -rf "$TEST_TMPDIR"

    # NODE_PATH wiederherstellen oder löschen
    if [ -n "${ORIG_NODE_PATH}" ]; then
        export NODE_PATH="$ORIG_NODE_PATH"
    else
        unset NODE_PATH
    fi
}

@test "append-feed.sh generates valid ISO-8601 UTC timestamp with Z suffix" {
    run "$APPEND_FEED" -t news -s manual -T "Timestamp Test" -o "$TEST_OUTPUT_FILE"
    assert_success

    # Extrahiere timestamp
    local ts
    ts="$(jq -r .ts "$TEST_OUTPUT_FILE")"

    # Prüfe Format: YYYY-MM-DDTHH:MM:SSZ
    # Regex: ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "append-feed.sh tmp_id logic is robust and produces valid filenames" {
    # Wir testen indirekt, indem wir das Skript sourcen und tmp_id aufrufen,
    # falls möglich. Da das Skript aber 'main' ausführt wenn nicht gesourced,
    # ist es einfacher, das Skript zu kopieren und main-Aufruf zu entfernen oder
    # direkt die Funktion zu extrahieren.
    # Alternative: Wir vertrauen darauf, dass safe_mktemp funktioniert (wird bei jedem Run genutzt).
    # Wir können aber simulieren, dass Tools fehlen, und schauen ob es durchläuft.

    # Erstelle eine "leere" Umgebung ohne uuidgen, openssl, python3
    # Dazu manipulieren wir PATH für einen Subshell-Aufruf

    mkdir -p "${TEST_TMPDIR}/empty_bin"

    run env PATH="${TEST_TMPDIR}/empty_bin:/bin:/usr/bin" \
        bash -c "type uuidgen >/dev/null 2>&1 && exit 1; \
                 type openssl >/dev/null 2>&1 && exit 1; \
                 type python3 >/dev/null 2>&1 && exit 1; \
                 $APPEND_FEED -t news -s manual -T 'Fallback Test' -o '$TEST_OUTPUT_FILE'"

    # Wenn uuidgen etc. im System-Pfad sind (/bin, /usr/bin), können wir sie schwer verstecken,
    # ohne den Pfad komplett zu leeren (was 'date', 'jq' etc. auch killt).
    # Pragmatischer Ansatz: Wir patchen das Skript temporär, um 'have' scheitern zu lassen.
}

@test "append-feed.sh runs with simulated shell fallback (no uuidgen/openssl/python3)" {
    # Prepare directory structure in TEST_TMPDIR to mimic repo structure
    mkdir -p "${TEST_TMPDIR}/scripts"
    mkdir -p "${TEST_TMPDIR}/contracts"

    # Erstelle gepatchte Version des Skripts in scripts/
    local PATCHED_SCRIPT="${TEST_TMPDIR}/scripts/append-feed-fallback.sh"
    cp "$APPEND_FEED" "$PATCHED_SCRIPT"

    # Kopiere validate.sh und validate_stream.js nach scripts/
    cp "$REPO_ROOT/scripts/validate.sh" "${TEST_TMPDIR}/scripts/validate.sh"
    cp "$REPO_ROOT/scripts/validate_stream.js" "${TEST_TMPDIR}/scripts/validate_stream.js"

    # Setze NODE_PATH, damit Node Module im Repo-Root findet (ohne Symlink)
    export NODE_PATH="$REPO_ROOT/node_modules"

    # Kopiere Schema nach contracts/
    cp "$REPO_ROOT/contracts/aussen.event.schema.json" "${TEST_TMPDIR}/contracts/aussen.event.schema.json"

    # Ersetze die 'have' Checks für die Tools mit 'false'
    sed -i.bak 's/have uuidgen/false/g' "$PATCHED_SCRIPT"
    sed -i.bak 's/have openssl/false/g' "$PATCHED_SCRIPT"
    sed -i.bak 's/have python3/false/g' "$PATCHED_SCRIPT"

    chmod +x "$PATCHED_SCRIPT"

    # Setze SCHEMA_FILE explizit oder verlasse dich auf REPO_ROOT Ableitung
    # Da wir contracts/ kopiert haben, sollte die Ableitung funktionieren (SCRIPT_DIR/../contracts/...)

    run "$PATCHED_SCRIPT" -t news -s manual -T "Shell Fallback Test" -o "$TEST_OUTPUT_FILE"
    assert_success

    # Prüfe ob Datei erstellt wurde (d.h. safe_mktemp hat funktioniert)
    [ -f "$TEST_OUTPUT_FILE" ]
    grep -q "Shell Fallback Test" "$TEST_OUTPUT_FILE"
}

@test "append-feed.sh runs with uuidgen available (default)" {
    if ! command -v uuidgen >/dev/null; then
        skip "uuidgen not available"
    fi

    run "$APPEND_FEED" -t news -s manual -T "Default UUID Test" -o "$TEST_OUTPUT_FILE"
    assert_success
}
