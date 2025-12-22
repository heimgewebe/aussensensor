#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

SCRIPT_UNDER_TEST="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/append-feed.sh"

setup() {
  # setup a temporary directory for the tests if needed, though mostly checking flags here
  export BATS_TMPDIR="$(mktemp -d -t bats-aussensensor-XXXXXX)"
}

teardown() {
  rm -rf "$BATS_TMPDIR"
}

@test "append-feed.sh handles missing argument nicely" {
  run "$SCRIPT_UNDER_TEST" -o
  assert_failure
  assert_output --partial "Fehler: Fehlender Parameter für -o"
}

@test "append-feed.sh handles missing argument for tags" {
  run "$SCRIPT_UNDER_TEST" -s source -t news -T title -g
  assert_failure
  assert_output --partial "Fehler: Fehlender Parameter für -g"
}
