#!/usr/bin/env bash
# Runs tests/github-read.test.cjs: the read helper's caller-mistake vs outage split, with a fake gh.
# A bad flag, a reshaped read, an unknown --json field or a 404 inside a readable repo fails that
# one call (exit 64); a 5xx, a 401 or an unreadable repo still halts the run (exit 79).
set -euo pipefail
cd "$(dirname "$0")/.."
node --test tests/github-read.test.cjs
echo 'PASS: test-github-read-node.sh'
