#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 "$ROOT/plugins/looker-to-sigma/skills/looker-to-sigma/tests/test_course_performance_fixture.py"
