#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate.sh"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/ref-resolution" && pwd)"

setup() {
  TEST_TMPDIR="$(mktemp -d -t bats-validate-ref-XXXXXX)"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "validate.sh: Resolves relative \$ref in schema" {
  local schema_file="$FIXTURES_DIR/schema-root.json"
  local valid_file="$FIXTURES_DIR/data-with-ref.jsonl"

  run "$VALIDATE_SCRIPT" -s "$schema_file" "$valid_file"
  assert_success
  assert_output --partial "OK: '$valid_file' ist valide."
}

@test "validate.sh: Fails correctly on invalid data with \$ref schema" {
  local schema_file="$FIXTURES_DIR/schema-root.json"
  local invalid_file="$FIXTURES_DIR/data-with-ref-invalid.jsonl"

  run "$VALIDATE_SCRIPT" -s "$schema_file" "$invalid_file"
  assert_failure 1
  # Nur auf "must be string" prüfen, da der Pfadpräfix (data/child/value) je nach Ajv-Version variieren kann
  assert_output --partial "must be string"
}

@test "validate.sh: Fails on missing schema file" {
  run "$VALIDATE_SCRIPT" -s "non_existent_schema.json" "$FIXTURES_DIR/data-with-ref.jsonl"
  assert_failure 1
  assert_output --partial "Schema nicht gefunden"
}

@test "validate.sh: Fails on invalid JSON schema" {
  local invalid_schema="$TEST_TMPDIR/invalid_schema.json"
  echo "{ invalid json" > "$invalid_schema"

  run "$VALIDATE_SCRIPT" -s "$invalid_schema" "$FIXTURES_DIR/data-with-ref.jsonl"
  assert_failure 1
  assert_output --partial "Failed to parse schema"
}
