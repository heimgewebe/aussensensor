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

@test "push_chronik.sh rejects non-http/https URLs (mixed case)" {
  run "$SCRIPT" --url "FILE:///etc/passwd" --file "$DUMMY_FILE" --dry-run
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

@test "push_chronik.sh accepts HTTP URLs (mixed case, dry-run)" {
  run "$SCRIPT" --url "HTTP://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}

@test "push_chronik.sh accepts HtTp URLs (mixed case, dry-run)" {
  run "$SCRIPT" --url "HtTp://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}

@test "push_chronik.sh rejects empty file" {
  local empty_file="$TEST_TMPDIR/empty.jsonl"
  touch "$empty_file"
  run "$SCRIPT" --url "http://localhost/ingest" --file "$empty_file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ist leer"* ]]
}

@test "push_chronik.sh accepts CURL_CONNECT_TIMEOUT env var (dry-run)" {
  run env CURL_CONNECT_TIMEOUT=5 "$SCRIPT" --url "http://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}

@test "push_chronik.sh accepts CURL_MAX_TIME env var (dry-run)" {
  run env CURL_MAX_TIME=30 "$SCRIPT" --url "http://localhost/ingest" --file "$DUMMY_FILE" --dry-run
  [ "$status" -eq 0 ]
}
