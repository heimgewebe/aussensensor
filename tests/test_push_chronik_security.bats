#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export SCRIPT="$REPO_ROOT/scripts/push_chronik.sh"
  export TEST_TMPDIR="$(mktemp -d)"
  export DUMMY_FILE="$TEST_TMPDIR/test.jsonl"
  echo '{"test":"data"}' > "$DUMMY_FILE"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "push_chronik.sh rejects non-http/https URLs" {
  run "$SCRIPT" --url "file:///etc/passwd" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehler: Ungültiges Protokoll"* ]]
}

@test "push_chronik.sh accepts http URLs (dry-run)" {
  run "$SCRIPT" --url "http://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}

@test "push_chronik.sh accepts https URLs (dry-run)" {
  run "$SCRIPT" --url "https://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}
