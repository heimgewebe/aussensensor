#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts"
VALIDATE_SCRIPT="$SCRIPT_DIR/validate.sh"
FIXTURES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/ref-resolution" && pwd)"

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
  assert_output --partial "data/child/value must be string"
}
