#!/usr/bin/env bash
set -euo pipefail

# Set the tests directory
TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Find the bats executable in the local clone
BATS_EXEC="$TESTS_DIR/bats/bin/bats"

# Run the tests
"$BATS_EXEC" "$TESTS_DIR"/test_append-feed.bats
