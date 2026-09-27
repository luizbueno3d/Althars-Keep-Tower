#!/bin/bash
# Development launcher. Althar's Keep — Tower has no save system yet
# (Phase 4), so there is nothing to isolate — but the flag and the
# env-var hook are wired now so a future save slot is separate from
# Althar's Keep's from the day it exists.
set -euo pipefail
cd "$(dirname "$0")/.."
export TOWER_SAVE="${TOWER_SAVE:-user://tower_save.json}"
exec tools/Godot.app/Contents/MacOS/Godot --path . "$@" -- --nosave
