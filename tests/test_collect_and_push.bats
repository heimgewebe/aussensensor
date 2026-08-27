#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/collect-and-push.sh"
  TEST_TMPDIR="$(mktemp -d "$REPO_ROOT/.test-collect-push.XXXXXX")"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "collect-and-push requires flock for transactional state safety" {
  local fake_bin="$TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  ln -s "$(command -v dirname)" "$fake_bin/dirname"
  ln -s "$(command -v mkdir)" "$fake_bin/mkdir"

  run env PATH="$fake_bin" AUSSENSENSOR_EXTERNAL_STATE="$TEST_TMPDIR/state.json" /bin/bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"flock is required for transactional state safety"* ]]
  [ ! -e "$TEST_TMPDIR/state.json" ]
}

@test "collect-and-push skips while another run holds the state lock" {
  local state_file="$TEST_TMPDIR/state.json"
  local lock_file="$TEST_TMPDIR/external-evidence.lock"

  exec 8>"$lock_file"
  flock -n 8
  run env AUSSENSENSOR_EXTERNAL_STATE="$state_file" "$SCRIPT"
  flock -u 8
  exec 8>&-

  [ "$status" -eq 0 ]
  [[ "$output" == *"another collection run owns the state lock"* ]]
  [ ! -e "$state_file" ]
}

@test "collect-and-push dry-run with no events never advances state" {
  local state_file="$TEST_TMPDIR/state.json"
  local before_file="$TEST_TMPDIR/state.before.json"
  local fake_python="$TEST_TMPDIR/fake-python"
  printf '%s\n' '{"schema_version":1,"sources":{"old":{"value":"keep"}}}' > "$state_file"
  cp "$state_file" "$before_file"

  cat > "$fake_python" <<'EOF'
#!/usr/bin/env bash
shift
next_state=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --next-state) next_state="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '{"schema_version":1,"sources":{"new":{"value":"candidate"}}}' > "$next_state"
: > "$output"
EOF
  chmod +x "$fake_python"

  run env PYTHON_BIN="$fake_python" AUSSENSENSOR_DRY_RUN=1 AUSSENSENSOR_EXTERNAL_STATE="$state_file" "$SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no relevant external change"* ]]
  [[ "$output" == *"dry-run; comparison state was not advanced"* ]]
  cmp "$before_file" "$state_file"
}
