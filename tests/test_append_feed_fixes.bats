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

@test "mix flags and positional args correctly" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  # -s mysource overrides the source slot, so "news" should be type, "My Title" should be title
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s mysource news "My Title" "Summary" "http://url"
  assert_success

  last_line=$(tail -n 1 "$feed_file")
  echo "$last_line" | grep '"type":"news"'
  echo "$last_line" | grep '"source":"mysource"'
  echo "$last_line" | grep '"title":"My Title"'
}

@test "omit url if empty" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s mysource -t news -T "No URL Title"
  assert_success
  last_line=$(tail -n 1 "$feed_file")
  echo "$last_line" | grep -v '"url":'
}

@test "omit url if explicitly empty string provided" {
  local feed_file="$BATS_TMPDIR/feed.jsonl"
  run "$SCRIPT_UNDER_TEST" -o "$feed_file" -s mysource -t news -T "Empty URL Title" -u ""
  assert_success
  last_line=$(tail -n 1 "$feed_file")
  echo "$last_line" | grep -v '"url":'
}
