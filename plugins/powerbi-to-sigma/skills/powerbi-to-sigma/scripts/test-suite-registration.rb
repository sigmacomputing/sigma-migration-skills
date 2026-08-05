#!/usr/bin/env ruby
# Regression test: every test file in this skill must be RUN by CI, and the canonical
# local command must cover the same set.
#
# WHY (2026-07-30). This plugin keeps tests in TWO directories — `scripts/test-*.rb` and
# `tests/*.rb`. A PR verified with a glob over `scripts/` only reported an accurate
# "33/33" and "35/35" while never running `tests/test-grounding.rb`, then merged and left
# `main` RED on 7 assertions in exactly that file. The numbers were true; the denominator
# was wrong.
#
# CI itself was fine — it lists `tests/test-grounding.rb` explicitly. The gap was that
# nothing enforced the relationship between "test files that exist" and "test files that
# run", so a new suite can be added and silently never execute, and nothing documented
# the local command that matches CI.
#
# This closes both: an unregistered suite fails here, and SKILL.md must state the
# both-directories command.
#
# Usage:  ruby scripts/test-suite-registration.rb
require 'set'

SKILL = File.expand_path('..', __dir__)
REPO  = File.expand_path('../../../..', SKILL)
WF    = File.join(REPO, '.github/workflows/corpus-check.yml')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

rel = ->(p) { p.sub("#{REPO}/", '') }
# Match on BASENAME, not the exact repo-relative path: the workflow lists some suites via
# a different path form (or a glob), and demanding an exact path produced false positives
# that would have masked the real gaps behind noise. Also scan EVERY workflow, since a
# suite may legitimately run from hygiene.yml rather than corpus-check.yml.
WFS = Dir[File.join(REPO, '.github/workflows/*.yml')].sort
ALL_WF = WFS.map { |f| File.read(f) }.join("\n")
registered = ->(path) { ALL_WF.include?(File.basename(path)) }

ruby_suites = (Dir[File.join(SKILL, 'scripts', 'test-*.rb')] +
               Dir[File.join(SKILL, 'tests', '*.rb')]).sort
py_suites   = (Dir[File.join(SKILL, 'scripts', 'test-*.py')] +
               Dir[File.join(SKILL, 'tests', 'test-*.py')]).sort

puts "\n1. this skill really does keep tests in TWO directories"
in_scripts = ruby_suites.count { |p| p.include?('/scripts/') }
in_tests   = ruby_suites.count { |p| p.include?('/tests/') }
check(in_scripts.positive?, "scripts/ holds ruby suites (#{in_scripts})", fails)
check(in_tests.positive?,
      "tests/ ALSO holds ruby suites (#{in_tests}) — the directory an earlier PR's glob missed", fails)

puts "\n2. every ruby suite is registered in the CI workflow"
check(!WFS.empty?, "workflows found (#{WFS.size})", fails)
missing = ruby_suites.reject { |p| registered.call(p) }
check(missing.empty?,
      "no ruby suite is unregistered (missing: #{missing.map { |p| File.basename(p) }.join(', ')})", fails)

puts "\n3. every python suite is registered too"
missing_py = py_suites.reject { |p| registered.call(p) }
check(missing_py.empty?,
      "no python suite is unregistered (missing: #{missing_py.map { |p| File.basename(p) }.join(', ')})", fails)

puts "\n4. SKILL.md documents the BOTH-directories local command"
skill_md = File.join(SKILL, 'SKILL.md')
md = File.exist?(skill_md) ? File.read(skill_md) : ''
check(File.exist?(skill_md), 'SKILL.md exists', fails)
check(md.include?('scripts/test-*.rb') && md.include?('tests/'),
      'SKILL.md names BOTH scripts/test-*.rb and tests/ in its verification command', fails)
check(md =~ /tests\/\*\.rb|tests\/test|both director/i,
      'and makes the two-directory requirement explicit', fails)

puts "\n5. the suite count is reported, so a shrinking denominator is visible"
puts "     ruby suites: #{ruby_suites.size} (scripts #{in_scripts} + tests #{in_tests})"
puts "     python suites: #{py_suites.size}"
check(ruby_suites.size + py_suites.size >= 30,
      "total suites #{ruby_suites.size + py_suites.size} — a sudden drop means a glob or a move broke", fails)

puts "\n#{fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)"}"
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
