#!/usr/bin/env bash
set -euo pipefail

# Set the tests directory
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Find the bats executable in the local clone (legacy path)
BATS_EXEC="$TESTS_DIR/bats/bin/bats"

# Fallback to system bats if local is not present
if [[ ! -x "$BATS_EXEC" ]]; then
  if command -v bats >/dev/null 2>&1; then
    BATS_EXEC="bats"
  else
    echo "bats executable not found (checked '$BATS_EXEC' and system PATH)." >&2
    echo "Please install bats." >&2
    exit 1
  fi
fi

# Run the tests
"$BATS_EXEC" "$TESTS_DIR"/*.bats
