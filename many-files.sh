#!/usr/bin/env bash

set -euo pipefail

TMPDIR="${SFHOME:-/opt/starfish}/tmp"
readonly NUM_THRESH="${1:-499}"

echo "Looking for directories with more than ${NUM_THRESH} local files: "
sf query --aggrs.total.files:gt $NUM_THRESH --format "volume path fn aggrs.total.files"
