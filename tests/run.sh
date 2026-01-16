#!/usr/bin/env bash
set -euo pipefail

# Set the tests directory
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Use system bats (no submodules)
if ! command -v bats >/dev/null 2>&1; then
  echo "Error: bats executable not found in PATH." >&2
  echo "Please install bats (examples):" >&2
  echo "  Debian/Ubuntu: sudo apt-get install bats (or: bats-core)" >&2
  echo "  macOS (brew):  brew install bats-core" >&2
  echo "  Arch:          sudo pacman -S bats" >&2
  echo "  See also: https://bats-core.readthedocs.io/" >&2
  exit 1
fi

# Run the tests
bats "$TESTS_DIR"/*.bats
