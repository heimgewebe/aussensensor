#!/usr/bin/env bash
set -euo pipefail

# Set the tests directory
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Find the bats executable in the local clone
BATS_EXEC="$TESTS_DIR/bats/bin/bats"

# Ensure bats submodules are available
if [[ ! -x "$BATS_EXEC" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$TESTS_DIR/.." rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$TESTS_DIR/.." submodule update --init --recursive
  fi
fi

if [[ ! -x "$BATS_EXEC" ]]; then
  echo "bats executable not found. Did 'git submodule update --init --recursive' succeed?" >&2
  exit 1
fi

# Run the tests
"$BATS_EXEC" "$TESTS_DIR"/*.bats
