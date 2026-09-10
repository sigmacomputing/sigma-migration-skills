#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-lint-twb-encoding.rb — self-test for the F5 crash-class gate (#752).
#
# A gate nobody has watched FAIL is not a gate. tools/lint-twb-encoding.rb grew a
# second rule because its first one could not see the crash that actually shipped
# (assert-phase6-ran.rb read a dm-spec.JSON raw and then .scan'd it: no .twb token
# in the argument, and RULE 1 excluded `.json` outright, so the site was never
# even a candidate). This file plants that exact defect — and the false-positive
# shapes that must NOT trip — in throwaway fixture trees and asserts the exit code
# each way round.
#
# Offline, creds-free, no network. Drives the lint via LINT_ROOT.

require 'fileutils'
require 'tmpdir'

LINT = File.expand_path('lint-twb-encoding.rb', __dir__)
fail_count = 0

def check(desc, cond)
  if cond
    puts "  ok   #{desc}"
  else
    puts "  FAIL #{desc}"
    $stdout.flush
    return false
  end
  true
end

# Run the lint against a fixture tree. Returns [exit_status, combined_output].
def run_lint(files)
  Dir.mktmpdir('lint-f5-') do |root|
    files.each do |rel, body|
      path = File.join(root, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    out = IO.popen({ 'LINT_ROOT' => root }, ['ruby', LINT], err: [:child, :out], &:read)
    [$?.exitstatus, out]
  end
end

def lint(files)
  run_lint(files)
end

puts 'test-lint-twb-encoding: F5 crash-class gate'

# ---------------------------------------------------------------------------
# THE PLANTED DEFECT: the shape that actually shipped broken (#752).
# ---------------------------------------------------------------------------
shipped_defect = <<~RUBY
  jp_dm = File.join(opts[:tab], 'dm-spec.json')
  jp_dm_src = File.exist?(jp_dm) ? (File.read(jp_dm) rescue '') : ''
  jp_dm_join_n = jp_dm_src.scan(/"kind"\\s*:\\s*"join"/).length
RUBY
code, out = lint('plugins/p/skills/s/scripts/gate.rb' => shipped_defect)
fail_count += 1 unless check('the #752 shape FAILS the gate (exit 1)', code == 1)
fail_count += 1 unless check('  ...and the offending read is named', out.include?('scripts/gate.rb:2'))
fail_count += 1 unless check('  ...and the match site is named', out.include?('gate.rb:3'))

# The fix must clear it — otherwise the gate is unsatisfiable and gets disabled.
fixed = shipped_defect.sub('File.read(jp_dm)', "File.read(jp_dm, encoding: 'UTF-8')")
code, = lint('plugins/p/skills/s/scripts/gate.rb' => fixed)
fail_count += 1 unless check("encoding: 'UTF-8' CLEARS it (exit 0)", code.zero?)

# ---------------------------------------------------------------------------
# RULE 1 must still work (the .twb-token rule it shipped with).
# ---------------------------------------------------------------------------
code, out = lint('plugins/p/skills/s/scripts/parse.rb' => "raw = File.read(twb)\n")
fail_count += 1 unless check('RULE 1 still catches an unencoded .twb read', code == 1)
code, = lint('plugins/p/skills/s/scripts/parse.rb' => "raw = File.read(twb, encoding: 'UTF-8')\n")
fail_count += 1 unless check('RULE 1 still passes an encoded .twb read', code.zero?)

# ---------------------------------------------------------------------------
# FALSE POSITIVES the gate must NOT trip on. Each of these is a shape that
# exists in-tree today; a gate that flags them is noise and gets turned off.
# ---------------------------------------------------------------------------
safe = {
  'JSON.parse tolerates locale-tagged bytes' =>
    "d = JSON.parse(File.read(p))\nd.to_s.scan(/x/)\n",
  'a read never pattern-matched' =>
    "body = File.read(p)\nFile.write(other, body)\n",
  'a read only compared / measured' =>
    "body = File.read(p)\nputs body.length if body.include?('x')\n",
  'reading its own source text (.rb literal)' =>
    "src = File.read(File.join(__dir__, 'other.rb'))\nsrc.scan(/def /)\n",
  'already encoded' =>
    "s = File.read(p, encoding: 'UTF-8')\ns.scan(/x/)\n"
}
safe.each do |desc, body|
  code, out = lint('plugins/p/skills/s/scripts/x.rb' => body)
  fail_count += 1 unless check("no false positive: #{desc}", code.zero?)
  puts out.lines.grep(/scripts\/x\.rb/).map { |l| "         #{l}" }.join unless code.zero?
end

# A test file is out of scope by design: the gate protects migration RUNS, and
# sweeping ~75 locale-fragile assertion helpers in would bury the real site.
code, = lint('plugins/p/skills/s/scripts/test-thing.rb' => shipped_defect)
fail_count += 1 unless check('test-*.rb is out of scope (documented narrowing)', code.zero?)

puts
if fail_count.zero?
  puts 'ALL PASS — the gate fails on the #752 shape, clears when fixed, and stays quiet on the safe shapes.'
  exit 0
end
puts "#{fail_count} check(s) FAILED"
exit 1
