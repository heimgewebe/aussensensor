#!/usr/bin/env bats

load 'bats-support/load.bash'
load 'bats-assert/load.bash'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "repository contains no obsolete 'leitstand' references" {
  run rg -in "leitstand" "$REPO_ROOT"
  assert_failure
  assert_output ""
}
