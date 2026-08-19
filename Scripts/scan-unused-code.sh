#!/usr/bin/env bash
#
# Report unused declarations via Periphery.
#
# Treat the output as candidates for deletion, never as a deletion list. System
# entry points (App Intents, widgets, URL handlers, app extensions) are invoked
# by iOS rather than by our own code, so they can appear unreachable while being
# load-bearing. Confirm each one has no system caller before removing it.
#
# Usage:
#   Scripts/scan-unused-code.sh            # human-readable report
#   FORMAT=json Scripts/scan-unused-code.sh > unused.json
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
format="${FORMAT:-xcode}"

if ! command -v periphery >/dev/null 2>&1; then
  printf 'periphery is not installed. Install it with: brew install periphery\n' >&2
  exit 127
fi

cd "$root_dir"

# Configuration lives in .periphery.yml so local and CI runs agree.
periphery scan --format "$format"
