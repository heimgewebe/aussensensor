#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

SCRIPT_UNDER_TEST="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/append-feed.sh"

setup() {
  # setup a temporary directory for the tests
  BATS_TMPDIR="$(mktemp -d -t bats-aussensensor-XXXXXX)"
}

teardown() {
  # cleanup the temporary directory
  rm -rf "$BATS_TMPDIR"
}

@test "append-feed.sh prints usage with -h" {
  run "$SCRIPT_UNDER_TEST" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "append-feed.sh fails with missing arguments" {
  run "$SCRIPT_UNDER_TEST"
  assert_failure
  assert_output --partial "Fehler: source, type und title dürfen nicht leer sein."
}

@test "append-feed.sh works with positional arguments" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" heise news "Titel" "Kurztext" "http://example.com"
  assert_success
  assert_output --partial "OK: Ereignis in '$feed_file' angehängt."
  run jq -e '.source == "heise"' "$feed_file"
  assert_success
}

@test "append-feed.sh fails with invalid type" {
  run "$SCRIPT_UNDER_TEST" -t invalid-type -s test -T "title"
  assert_failure
  assert_output --partial "Fehler: type muss einer von {news|sensor|project|alert} sein."
}

@test "append-feed.sh fails with summary too long" {
  local long_summary
  long_summary="$(printf '%501s' | tr ' ' 'a')"
  run "$SCRIPT_UNDER_TEST" -s test -t news -T "title" -S "$long_summary"
  assert_failure
  assert_output --partial "Fehler: summary darf höchstens 500 Zeichen umfassen"
}

@test "append-feed.sh handles positional tags" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" s news "title" "summary" "url" tag1 tag2
  assert_success
  run jq -e '.tags | length == 2 and .[0] == "tag1" and .[1] == "tag2"' "$feed_file"
  assert_success
}

@test "append-feed.sh handles comma-separated tags" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s s -t news -T "title" -g "tag1,tag2, tag3"
  assert_success
  run jq -e '.tags | length == 3 and .[2] == "tag3"' "$feed_file"
  assert_success
}

@test "append-feed.sh deduplicates tags" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s s -t news -T "title" -g "tag1,tag2,tag1"
  assert_success
  run jq -e '.tags | length == 2' "$feed_file"
  assert_success
}

@test "append-feed.sh works with named flags" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s heise -t news -T "Titel" -S "Kurztext" -u "http://example.com"
  assert_success
  assert_output --partial "OK: Ereignis in '$feed_file' angehängt."
  run jq -e '.source == "heise"' "$feed_file"
  assert_success
}
