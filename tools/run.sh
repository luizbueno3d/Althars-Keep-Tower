#!/bin/bash
# Launch Althar's Keep — Tower.
# Extra engine flags pass through; game flags go after `--`, e.g.
#   tools/run.sh -- --shot=6:/tmp/tower.png
set -euo pipefail
cd "$(dirname "$0")/.."
exec tools/Godot.app/Contents/MacOS/Godot --path . "$@"
