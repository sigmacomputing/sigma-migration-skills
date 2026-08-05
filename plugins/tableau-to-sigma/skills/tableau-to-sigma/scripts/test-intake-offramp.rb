#!/usr/bin/env ruby
# test-intake-offramp.rb — every plugin front-door's --skip-bootstrap-gate must
# leave a skip-flag-waived record in <workdir>/offramps.jsonl (PLAN-v4 F6b).
# The audit trail is the flag's entire contract: intake.rb requires the
# VENDORED lib/offramp.rb, so a plugin missing that one file warns and records
# NOTHING — a silent no-op this test exists to make loud. From a repo checkout
# it sweeps every plugins/*/skills/*/scripts/intake.rb; a vendored standalone
# copy falls back to the intake.rb next to it.
# Canonical in shared/scripts. Run: ruby scripts/test-intake-offramp.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'

RUBY = RbConfig.ruby
UUID = '11111111-2222-3333-4444-555555555555'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

root = __dir__
root = File.dirname(root) until File.exist?(File.join(root, 'shared', 'manifest.json')) ||
                                File.dirname(root) == root
intakes = if File.exist?(File.join(root, 'shared', 'manifest.json'))
            Dir[File.join(root, 'plugins', '*', 'skills', '*', 'scripts', 'intake.rb')].sort
          else
            [File.join(__dir__, 'intake.rb')].select { |p| File.exist?(p) }
          end
ok('found at least one intake.rb to audit', !intakes.empty?)

intakes.each do |intake|
  label = intake.sub(%r{\A#{Regexp.escape(root)}/?}, '')
  Dir.mktmpdir do |d|
    wd = File.join(d, 'wd')
    home = File.join(d, 'home')
    FileUtils.mkdir_p([wd, home])
    # --connection <UUID> resolves via the flag — offline, no API. HOME is
    # scratch so a real ~/.sigma-migration on the dev machine can't leak in.
    env = { 'HOME' => home, 'USERPROFILE' => home,
            'SIGMA_CONNECTION_ID' => nil, 'SIGMA_SKIP_BOOTSTRAP_GATE' => nil }
    system(env, RUBY, intake, '--workdir', wd, '--skip-bootstrap-gate', 'unit-test',
           '--connection', UUID, out: File::NULL, err: File::NULL)
    trail = File.join(wd, 'offramps.jsonl')
    rec = File.exist?(trail) && File.readlines(trail).any? do |l|
      j = (JSON.parse(l) rescue nil)
      j.is_a?(Hash) && j['kind'] == 'skip-flag-waived' && j['detail'] == '--skip-bootstrap-gate'
    end
    ok("#{label}: waiver recorded to offramps.jsonl", rec)
  end
end

puts $fail.zero? ? "\nall intake-offramp tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
