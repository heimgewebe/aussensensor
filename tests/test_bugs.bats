#!/usr/bin/env bats

setup() {
  export SCRIPT_DIR="scripts"
  export APPEND_SCRIPT="$SCRIPT_DIR/append-feed.sh"
}

@test "append-feed.sh handles missing argument nicely" {
  run ./scripts/append-feed.sh -o
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehlender Parameter für -o"* ]]
}

@test "append-feed.sh handles missing argument for tags" {
  run ./scripts/append-feed.sh -s source -t news -T title -g
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fehlender Parameter für -g"* ]]
}
