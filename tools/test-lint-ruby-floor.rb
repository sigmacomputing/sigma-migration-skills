#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-lint-ruby-floor.rb — self-test for the Ruby 2.6 floor gate.
#
# Each of the four rules below corresponds to a mistake actually made while
# landing the polyfill, which is why the gate checks placement and not just
# presence:
#   * MISSING   — 57 call sites had no polyfill at all (the original bug).
#   * NESTED    — build-workbook-spec.rb got the require inside an indented
#                 block, so it never ran and the test still failed.
#   * ORDERED   — validate-spec.rb got the require at L72 with the use at L38.
#   * ENDLESS   — verify-layout-contract-e2e.rb shipped a Ruby 3.0 endless def
#                 that CI's 3.3 `ruby -c` parses happily.
#
# Offline, creds-free. Drives the lint via LINT_ROOT.

require 'fileutils'
require 'tmpdir'

LINT = File.expand_path('lint-ruby-floor.rb', __dir__)
fails = 0

def check(desc, cond)
  puts(cond ? "  ok   #{desc}" : "  FAIL #{desc}")
  cond
end

# Writes files under <tmp>/plugins/p/skills/s/scripts/ and runs the lint there.
def lint(files)
  Dir.mktmpdir('ruby-floor-') do |root|
    base = File.join(root, 'plugins', 'p', 'skills', 's', 'scripts')
    FileUtils.mkdir_p(File.join(base, 'lib'))
    # the polyfill must exist for the "fixed" cases to be satisfiable
    File.write(File.join(base, 'lib', 'ruby_compat.rb'), "# stub polyfill\n")
    files.each do |rel, body|
      path = File.join(base, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    out = IO.popen({ 'LINT_ROOT' => root }, ['ruby', LINT], err: [:child, :out], &:read)
    [$?.exitstatus, out]
  end
end

puts 'test-lint-ruby-floor: ruby 2.6 floor gate'

# --- RULE 1: missing entirely ----------------------------------------------
code, out = lint('a.rb' => "x = [1].filter_map { |v| v }\n")
fails += 1 unless check('MISSING: 2.7+ method with no polyfill FAILS', code == 1)
fails += 1 unless check('  ...names the method line', out.include?('a.rb:1'))

code, = lint('a.rb' => "require_relative 'lib/ruby_compat'\nx = [1].filter_map { |v| v }\n")
fails += 1 unless check('  ...and a correct require CLEARS it', code.zero?)

# --- RULE 2: nested inside a block -----------------------------------------
nested = <<~RUBY
  def go
    require_relative 'lib/ruby_compat'
    [1].filter_map { |v| v }
  end
RUBY
code, out = lint('b.rb' => nested)
fails += 1 unless check('NESTED: require inside an indented block FAILS', code == 1)
fails += 1 unless check('  ...says it may never execute', out.include?('may never execute'))

# --- RULE 3: require after first use ---------------------------------------
ordered = <<~RUBY
  x = [1].filter_map { |v| v }
  require_relative 'lib/ruby_compat'
RUBY
code, out = lint('c.rb' => ordered)
fails += 1 unless check('ORDERED: require AFTER first use FAILS', code == 1)
fails += 1 unless check('  ...reports the use line', out.include?('AFTER first use (line 1)'))

# --- RULE 4: ruby 3.0 endless def ------------------------------------------
code, out = lint('d.rb' => "def log(m) = puts(m)\n")
fails += 1 unless check('ENDLESS: ruby 3.0 endless def FAILS', code == 1)
fails += 1 unless check('  ...calls it a 2.6 SyntaxError', out.include?('SyntaxError on 2.6'))
code, = lint('d.rb' => "def log(m)\n  puts(m)\nend\n")
fails += 1 unless check('  ...and the classic form is fine', code.zero?)

# --- false positives the gate must NOT trip on -----------------------------
quiet = {
  'a comment mentioning filter_map' => "# not filter_map -- that is 2.7+\nx = [1].map { |v| v }.compact\n",
  'plain 2.6-safe code'             => "x = [1].map { |v| v }.compact\n",
  'keyword-arg default with ='      => "def f(a: 1)\n  a\nend\n",
  'assignment to a method result'   => "y = 1\nz = y\n",
  'the polyfill file itself'        => nil
}
quiet.each do |desc, body|
  next if body.nil?
  code, out = lint('e.rb' => body)
  ok = check("no false positive: #{desc}", code.zero?)
  fails += 1 unless ok
  puts out.lines.grep(/e\.rb/).map { |l| "         #{l}" }.join unless ok
end

puts
if fails.zero?
  puts 'ALL PASS — gate fails on all four real mistakes and stays quiet on 2.6-safe code.'
  exit 0
end
puts "#{fails} check(s) FAILED"
exit 1
