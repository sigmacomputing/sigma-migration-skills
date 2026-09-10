#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-lint-twin-parity.rb — self-test for the .rb/.py twin-parity gate (#753).
#
# A gate nobody has watched FAIL is not a gate. This drives
# tools/lint-twin-parity.rb against throwaway fixture pairs and asserts, in both
# directions:
#
#   * a genuinely deleted function FAILS (that is the bug class #753 is about);
#   * every shape the naive `grep '^def '` diff got WRONG stays quiet — Python's
#     `_` privacy marker, Ruby `private` regions, `def self.` escaping `private`,
#     `?`/`!` suffixes, initialize/__init__, and deliberate renames. Five of the
#     nine rows in the original report were one of these.
#
# The second half matters as much as the first: a gate that reports 12 phantom
# gaps on a clean tree gets switched off, and then the real one ships.
#
# Offline, creds-free, no network. Drives the lint via LINT_ROOT + TWIN_LIB_DIR.

require 'fileutils'
require 'tmpdir'

LINT = File.expand_path('lint-twin-parity.rb', __dir__)
fails = 0

def check(desc, cond)
  puts(cond ? "  ok   #{desc}" : "  FAIL #{desc}")
  cond
end

# files: { 'mod.rb' => src, 'mod.py' => src } — written into <tmp>/shared/lib/
def lint(files)
  Dir.mktmpdir('twin-parity-') do |root|
    dir = File.join(root, 'shared', 'lib')
    FileUtils.mkdir_p(dir)
    files.each { |name, body| File.write(File.join(dir, name), body) }
    out = IO.popen({ 'LINT_ROOT' => root, 'TWIN_LIB_DIR' => 'shared/lib' },
                   ['ruby', LINT], err: [:child, :out], &:read)
    [$?.exitstatus, out]
  end
end

puts 'test-lint-twin-parity: .rb/.py twin API parity'

# ---------------------------------------------------------------------------
# THE BUG CLASS: a function that genuinely has no counterpart.
# ---------------------------------------------------------------------------
code, out = lint(
  'm.rb' => "module M\n  module_function\n  def alpha; end\n  def beta; end\nend\n",
  'm.py' => "def alpha():\n    pass\n"
)
fails += 1 unless check('a genuinely missing function FAILS (exit 1)', code == 1)
fails += 1 unless check('  ...and names it', out.include?('`beta`'))
fails += 1 unless check('  ...and does not cry about the one that IS there', !out.include?('`alpha`'))

# Porting it clears the gate — otherwise the gate is unsatisfiable.
code, = lint(
  'm.rb' => "module M\n  module_function\n  def alpha; end\n  def beta; end\nend\n",
  'm.py' => "def alpha():\n    pass\n\n\ndef beta():\n    pass\n"
)
fails += 1 unless check('porting it CLEARS the gate (exit 0)', code.zero?)

# ---------------------------------------------------------------------------
# FALSE POSITIVES — each of these is a row the original `^def` diff got wrong.
# ---------------------------------------------------------------------------
quiet = {
  "Python `_` privacy marker (metric_binding.walk_chain -> _walk_chain)" => [
    "module M\n  module_function\n  def walk_chain; end\nend\n",
    "def _walk_chain():\n    pass\n"
  ],
  "Ruby `private` region (all three code_rep methods live below its `private`)" => [
    "module M\n  def pub; end\n  private\n  def helper; end\nend\n",
    "def pub():\n    pass\n"
  ],
  "`def self.` stays public inside a `private` region (coverage_catalog)" => [
    "class C\n  private\n  def inst; end\nend\nmodule M\n  def self.load; end\nend\n",
    "def load():\n    pass\n"
  ],
  "Ruby predicate suffix (sigma_rest.token_stale? -> token_stale)" => [
    "module M\n  module_function\n  def token_stale?; end\nend\n",
    "def token_stale():\n    pass\n"
  ],
  "Ruby bang suffix (refresh_token! -> refresh_token)" => [
    "module M\n  module_function\n  def refresh_token!; end\nend\n",
    "def refresh_token():\n    pass\n"
  ],
  "initialize <-> __init__ (coverage_catalog constructor convention)" => [
    "class C\n  def initialize(a); end\nend\n",
    "class C:\n    def __init__(self, a):\n        pass\n"
  ],
  "class methods on both sides, not just module-level `^def`" => [
    "class C\n  def resolve(k); end\nend\n",
    "class C:\n    def resolve(self, k):\n        pass\n"
  ]
}
quiet.each do |desc, (rb, py)|
  code, out = lint('m.rb' => rb, 'm.py' => py)
  ok = check("no false positive: #{desc}", code.zero?)
  fails += 1 unless ok
  puts out.lines.grep(/`/).map { |l| "         #{l}" }.join unless ok
end

# A deliberate rename is a mapping, not a gap — but only for the module that
# declares it (warehouse_transforms), so this fixture module must still fail.
code, = lint(
  'warehouse_transforms.rb' => "module M\n  module_function\n  def apply; end\n  def detect; end\nend\n",
  'warehouse_transforms.py' => "def apply_transforms():\n    pass\n\n\ndef detect_warehouse():\n    pass\n"
)
fails += 1 unless check('declared RENAMES are honoured (warehouse_transforms)', code.zero?)

# ---------------------------------------------------------------------------
# The allow-list must not rot into a permanent exemption.
# ---------------------------------------------------------------------------
code, out = lint(
  'sigma_rest.rb' => "module M\n  module_function\n  def list_entries; end\nend\n",
  'sigma_rest.py' => "def list_entries():\n    pass\n"
)
fails += 1 unless check('a STALE allow-list entry FAILS (the name now exists)', code == 1)
fails += 1 unless check('  ...and says to delete it', out.include?('delete this allow-list entry'))

# A visibility-only difference is reported but must NOT fail the build.
code, out = lint(
  'm.rb' => "module M\n  module_function\n  def helper; end\nend\n",
  'm.py' => "def _helper():\n    pass\n"
)
fails += 1 unless check('visibility-only difference passes but IS reported', code.zero?)
fails += 1 unless check('  ...and is labelled as not-missing', out.include?('helper -> _helper'))

# A pair with no .py twin is out of scope (most shared/lib is ruby-only).
code, = lint('rubyonly.rb' => "module M\n  def x; end\nend\n")
fails += 1 unless check('a .rb with no .py twin is out of scope', code.zero?)

puts
if fails.zero?
  puts 'ALL PASS — fails on a real gap and on a stale exemption; quiet on all 7 false-positive shapes.'
  exit 0
end
puts "#{fails} check(s) FAILED"
exit 1
