#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

LINTER = File.expand_path('lint-uplift-contracts.rb', __dir__)

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
end

def run_lint(root)
  stdout, stderr, status = Open3.capture3(
    { 'UPLIFT_CONTRACTS_ROOT' => root },
    'ruby', LINTER
  )
  [status.success?, "#{stdout}#{stderr}"]
end

def assert(condition, message, output = nil)
  return if condition

  warn "FAIL: #{message}"
  warn output if output
  exit 1
end

Dir.mktmpdir('lint-uplift-contracts') do |root|
  skill = File.join(root, 'plugins/fake-to-sigma/skills/fake-to-sigma')
  matrix = File.join(skill, 'refs/fake-coverage.md')
  open_items = File.join(skill, 'refs/open-items.md')

  write(File.join(skill, 'refs/catalogs/viz-kind.json'), "{}\n")
  write(
    File.join(skill, 'scripts/gen-coverage-matrix.py'),
    <<~'PY'
      import argparse
      import pathlib
      import sys

      parser = argparse.ArgumentParser()
      parser.add_argument("--catalogs", required=True)
      parser.add_argument("--skill", required=True)
      parser.add_argument("--out", required=True)
      parser.add_argument("--check", action="store_true")
      args = parser.parse_args()
      expected = (
          "# Fake coverage\n\n"
          "> **GENERATED — do not edit by hand.** Regenerate with "
          "`python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs "
          "--skill fake --out refs/fake-coverage.md`.\n"
      )
      current = pathlib.Path(args.out).read_text() if pathlib.Path(args.out).exists() else ""
      if args.check and current != expected:
          print("STALE: generated coverage differs", file=sys.stderr)
          raise SystemExit(1)
      pathlib.Path(args.out).write_text(expected)
    PY
  )
  write(
    matrix,
    <<~MD
      # Fake coverage

      > **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill fake --out refs/fake-coverage.md`.
    MD
  )
  write(
    open_items,
    <<~MD
      # Open items

      | ID | Status | Evidence | Description |
      |---|---|---|---|
      | F-1 | open | [fixture](https://example.test/open) | Needs implementation |
      | F-2 | blocked | issue-2 | Waiting on upstream |
      | F-3 | resolved | commit-3 | Shipped |
      | F-4 | accepted | decision-4 | Accepted limitation |
      | F-5 | not-applicable | source-5 | Source feature absent |
    MD
  )

  special = File.join(root, 'plugins/special-to-sigma/skills/special-to-sigma')
  write(File.join(special, 'refs/catalogs/viz-kind.json'), "{}\n")
  write(File.join(special, 'scripts/gen-coverage-matrix.py'), "raise SystemExit('generic generator must not run')\n")
  write(
    File.join(special, 'scripts/gen-special-coverage.py'),
    <<~'PY'
      import argparse
      import pathlib

      parser = argparse.ArgumentParser()
      parser.add_argument("--catalogs", required=True)
      parser.add_argument("--skill", required=True)
      parser.add_argument("--out", required=True)
      parser.add_argument("--check", action="store_true")
      args = parser.parse_args()
      text = pathlib.Path(args.out).read_text()
      if not args.check or "GENERATED" not in text:
          raise SystemExit(1)
    PY
  )
  write(
    File.join(special, 'refs/special-coverage.md'),
    <<~MD
      # Special coverage

      > **GENERATED.** Regenerate with `python3 scripts/gen-special-coverage.py --catalogs refs/catalogs --skill special --out refs/special-coverage.md`.
    MD
  )

  success, output = run_lint(root)
  assert(success, 'expected valid generic, specialized, and open-items fixtures to pass', output)

  write(matrix, "stale\n")
  success, output = run_lint(root)
  assert(!success, 'expected stale coverage fixture to fail', output)
  assert(output.include?('[coverage-stale]'), 'expected coverage-stale rule in output', output)

  FileUtils.rm_f(matrix)
  success, output = run_lint(root)
  assert(!success, 'expected missing inferred coverage fixture to fail', output)
  assert(output.include?('[coverage-missing]'), 'expected coverage-missing rule in output', output)

  write(
    matrix,
    <<~MD
      # Fake coverage

      > **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill fake --out refs/fake-coverage.md`.
    MD
  )
  write(
    open_items,
    <<~MD
      # Open items

      | ID | Status | Evidence | Detail |
      |---|---|---|---|
      |  | pending | TBD |  |
      | F-7 | open |  | Missing evidence |
      | F-8 | blocked | - | Placeholder evidence |
    MD
  )
  success, output = run_lint(root)
  assert(!success, 'expected malformed open-items fixture to fail', output)
  %w[open-items-id open-items-status open-items-evidence open-items-detail].each do |rule|
    assert(output.include?("[#{rule}]"), "expected #{rule} rule in output", output)
  end

  write(
    open_items,
    <<~MD
      # Open items

      | ID | Status | Evidence | Detail / Description |
      |---|---|---|---|
      | F-6 | `resolved` | verification-log.txt | Verified in fixture |
    MD
  )
  success, output = run_lint(root)
  assert(success, 'expected repaired open-items fixture to pass', output)
end

puts 'OK: tools/test-lint-uplift-contracts.rb'
