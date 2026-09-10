#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-ruby-floor.rb — keeps the documented Ruby 2.6 floor actually true.
#
# Every converter documents a 2.6 floor (macOS system Ruby) so an agent never
# has to install a runtime mid-migration; 30 comments across the tree say "not
# filter_map — that's Ruby 2.7+". 57 call sites landed anyway, because NOTHING
# could see them:
#
#   * `ruby -c` (the script-syntax CI job) cannot: a missing METHOD is a runtime
#     NoMethodError, not a syntax error.
#   * CI runs Ruby 3.3, where the methods exist.
#   * doctor.sh printed the Ruby version without asserting any floor, so 2.6.10
#     passed green while the code needed 2.7.
#
# Measured field impact under system 2.6, 277 tableau test files: 7 died with a
# clean `undefined method 'filter_map'`, and 6 more reported a SEMANTIC failure
# instead (e.g. "per-dashboard derivation: Fixed=74, Auto=48 (got {})") because a
# sub-script crashed, something rescued it, and the caller continued with empty
# data. Silent degradation is the reason this is a gate and not a style note.
#
# The fix is a polyfill (shared/lib/ruby_compat.rb), not 57 rewrites — so what
# this gate enforces is that the polyfill is actually IN EFFECT wherever it is
# needed. Three conditions, all three of which a careful manual pass got wrong
# at least once while landing it:
#
#   1. PRESENT  — a file using a 2.7+ method requires ruby_compat at all.
#   2. TOP-LEVEL— the require is at column 0, not nested inside a def/if/block
#                 that may never execute (hit once: build-workbook-spec.rb).
#   3. ORDERED  — the require precedes the first use in the file
#                 (hit once: validate-spec.rb, require L72 vs use L38).
#
# Plus a syntax rule `ruby -c` under 3.x cannot express: no Ruby 3.0+ endless
# method defs (`def f = expr`), which are a hard SyntaxError on 2.6.
#
# Exit 0 = clean; exit 1 = at least one violation. LINT_ROOT for the self-test.

ROOT = ENV['LINT_ROOT'] || File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# Methods absent from Ruby 2.6 that shared/lib/ruby_compat.rb polyfills.
# Keep in lockstep with that file: a method polyfilled there but missing here is
# unenforced, and one here but not there makes the gate unsatisfiable.
POLYFILLED = /\.(?:filter_map|tally)\b|\.except\(/
# Ruby 3.0+ endless method definition — SyntaxError on 2.6, parses fine on 3.x,
# so the script-syntax job is blind to it.
ENDLESS_DEF = /^\s*def\s+[a-zA-Z_][a-zA-Z_0-9]*[?!]?(?:\([^)]*\))?\s*=\s*[^=]/

SKIP_DIRS = %r{^(?:docs/|\.git/)}
# A gate's own self-test necessarily EMBEDS violating code as fixture strings
# (tools/test-lint-ruby-floor.rb heredocs an indented require on purpose to
# prove the NESTED rule fires). Scanning it flags the fixtures, not real code.
SKIP_FILES = %r{^tools/test-lint-.*\.rb$}

def strip_comments(line)
  # Good enough for this gate: drop a whole-line comment. An inline `#` inside a
  # string would be a false positive, so require the # to start the line.
  line.lstrip.start_with?('#') ? '' : line
end

violations = []

Dir.glob('{plugins,shared,tools}/**/*.rb').sort.each do |path|
  next if path =~ SKIP_DIRS
  next if path =~ SKIP_FILES
  next if File.basename(path) == 'ruby_compat.rb'   # the polyfill itself
  src = File.read(path, encoding: 'UTF-8')
  lines = src.lines

  lines.each_with_index do |line, i|
    next if strip_comments(line).empty?
    next unless line =~ ENDLESS_DEF
    violations << ["#{path}:#{i + 1}", 'ruby 3.0+ endless method def is a SyntaxError on 2.6', line.strip]
  end

  use_idx = lines.index { |l| !strip_comments(l).empty? && strip_comments(l) =~ POLYFILLED }
  next unless use_idx

  req_idx = lines.index do |l|
    l.start_with?('require_relative', 'require') && l.include?('ruby_compat')
  end
  nested  = lines.index { |l| l =~ /\A\s+require(?:_relative)?\b.*ruby_compat/ }

  if req_idx.nil? && nested.nil?
    violations << ["#{path}:#{use_idx + 1}", 'uses a 2.7+ method but never requires ruby_compat', lines[use_idx].strip]
  elsif req_idx.nil? && nested
    violations << ["#{path}:#{nested + 1}", 'requires ruby_compat INSIDE an indented block — may never execute', lines[nested].strip]
  elsif req_idx > use_idx
    violations << ["#{path}:#{req_idx + 1}", "requires ruby_compat AFTER first use (line #{use_idx + 1})", lines[req_idx].strip]
  end
end

if violations.empty?
  puts 'OK: ruby 2.6 floor holds (every 2.7+ method use is polyfilled, in scope, and in order; no endless defs).'
  exit 0
end

warn '::error::Ruby 2.6 floor violated — an agent on stock macOS ruby will hit this at RUNTIME:'
violations.each { |loc, why, code| warn "  #{loc}: #{why}\n      #{code}" }
warn ''
warn "Fix: require_relative '<path>/lib/ruby_compat' at COLUMN 0, ABOVE the first use."
warn 'Or, if the file genuinely needs a newer Ruby, say so in the skill docs and raise the floor deliberately.'
exit 1
