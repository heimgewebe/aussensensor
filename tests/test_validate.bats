#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate.sh"
SCHEMA_FILE="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/contracts/aussen.event.schema.json"

setup() {
  BATS_TMPDIR="$(mktemp -d -t bats-validate-XXXXXX)"
}

teardown() {
  rm -rf "$BATS_TMPDIR"
}

@test "validate.sh: Valid file returns 0" {
  local valid_file="$BATS_TMPDIR/valid.jsonl"
  echo '{"ts":"2025-01-01T00:00:00Z","type":"news","source":"manual","title":"Test","summary":"","tags":[]}' > "$valid_file"

  run "$VALIDATE_SCRIPT" -s "$SCHEMA_FILE" "$valid_file"
  assert_success
  assert_output --partial "OK: '$valid_file' ist valide."
}

@test "validate.sh: Invalid file returns 1" {
  local invalid_file="$BATS_TMPDIR/invalid.jsonl"
  echo '{"ts":"2025-01-01T00:00:00Z","type":"news","title":"Missing Source"}' > "$invalid_file"

  run "$VALIDATE_SCRIPT" -s "$SCHEMA_FILE" "$invalid_file"
  assert_failure 1
  assert_output --partial "must have required property 'source'"
}

@test "validate.sh: Empty file returns 0 (warning)" {
  local empty_file="$BATS_TMPDIR/empty.jsonl"
  touch "$empty_file"

  run "$VALIDATE_SCRIPT" -s "$SCHEMA_FILE" "$empty_file"
  assert_success
  assert_output --partial "⚠️  Keine Ereignisse zur Validierung in '$empty_file'"
}

@test "validate.sh: Empty file with REQUIRE_NONEMPTY=1 returns 1" {
  local empty_file="$BATS_TMPDIR/empty.jsonl"
  touch "$empty_file"

  run env REQUIRE_NONEMPTY=1 "$VALIDATE_SCRIPT" -s "$SCHEMA_FILE" "$empty_file"
  assert_failure 1
  assert_output --partial "❌ Keine Ereignisse zur Validierung in '$empty_file'"
}

@test "validate.sh: Stdin valid returns 0" {
  run bash -c "echo '{\"ts\":\"2025-01-01T00:00:00Z\",\"type\":\"news\",\"source\":\"manual\",\"title\":\"Test\",\"summary\":\"\",\"tags\":[]}' | \"$VALIDATE_SCRIPT\" -s \"$SCHEMA_FILE\""
  assert_success
  assert_output --partial "OK: Stdin-Daten sind valide."
}

@test "validate.sh: Stdin empty returns 0 (warning)" {
  run bash -c "echo -n | \"$VALIDATE_SCRIPT\" -s \"$SCHEMA_FILE\""
  assert_success
  assert_output --partial "⚠️  Keine Daten auf stdin erhalten."
}
