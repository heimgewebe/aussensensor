#!/usr/bin/env bash

# Shared shell utilities for the aussensensor project.

# have(command) returns 0 if command is in PATH, 1 otherwise.
have() {
  command -v "$1" >/dev/null 2>&1
}

# need(command) exits with error message if command is NOT in PATH.
need() {
  if ! have "$1"; then
    echo "Fehler: '$1' wird benötigt, ist aber nicht im PATH." >&2
    exit 1
  fi
}
