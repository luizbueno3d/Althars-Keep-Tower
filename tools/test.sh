#!/bin/bash
# Test entry point for Althar's Keep — Tower.
#
# 1. The vendored rules must match Althar's Keep byte-for-byte.
# 2. The tower scenario must satisfy the config contract and run.
# 3. Althar's Keep's own suite must stay green — those are the rules
#    this game plays by, and it shares them.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== rules sync (sim/ vs Althar's Keep) =="
tools/sync-rules.sh --check

echo
echo "== tower scenario probe =="
tools/probe.sh

echo
echo "== tower suite =="
tools/Godot.app/Contents/MacOS/Godot --headless --path . \
	-s res://tests/run_tests.gd

echo
echo "== shared rules engine suite (Althar's Keep) =="
../benchmarks/godot/tools/test.sh 2>&1 | tail -3
