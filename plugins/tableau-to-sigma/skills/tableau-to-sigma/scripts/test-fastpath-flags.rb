#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for the migrate-tableau.rb FAST PATH (--reuse-dm + --wb-spec):
#   1. the routing predicate (lib/fast_path.rb decide — a pure function, so the
#      skip-decision logic is tested without any Tableau/Sigma calls);
#   2. the BOM-tolerant JSON reader (read_json_utf8 — PowerShell's
#      `Set-Content -Encoding UTF8` BOM must not break workdir spec reads);
#   3. flag parsing: `migrate-tableau.rb --help` exits 0 and documents the
#      fast-path flags/semantics.
# Deterministic, no network. Usage: ruby scripts/test-fastpath-flags.rb

require 'json'
require 'tmpdir'
require_relative 'lib/fast_path'

DIR     = __dir__
MIGRATE = File.join(DIR, 'migrate-tableau.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

ALL_PRESENT = { 'dashboard-layout.json' => true, 'views/*.csv' => true,
                'workbook-content.twb' => true }.freeze
NONE_PRESENT = ALL_PRESENT.transform_values { false }.freeze

puts '— decide(): routing —'

# 1. Both flags, explicit id, complete workdir → FAST, not degraded.
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb-spec.json', artifacts: ALL_PRESENT)
check(d[:route] == :fast && d[:degraded].empty?,
      "explicit --reuse-dm + --wb-spec + complete workdir → :fast (got #{d[:route]}, degraded=#{d[:degraded]})", fails)

# 2. Bare --reuse-dm (:recommended) → FULL (the recommendation needs the reuse scan).
d = FastPath.decide(reuse_dm: :recommended, wb_spec: '/w/wb-spec.json', artifacts: ALL_PRESENT)
check(d[:route] == :full && d[:reason] =~ /explicit/,
      "bare --reuse-dm (recommended) → :full (got #{d[:route]})", fails)

# 3. --wb-spec without --reuse-dm → FULL.
d = FastPath.decide(reuse_dm: nil, wb_spec: '/w/wb-spec.json', artifacts: ALL_PRESENT)
check(d[:route] == :full, "--wb-spec alone → :full (got #{d[:route]})", fails)

# 4. --reuse-dm without --wb-spec → FULL.
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: nil, artifacts: ALL_PRESENT)
check(d[:route] == :full, "--reuse-dm alone → :full (got #{d[:route]})", fails)

# 5. --dm-spec (fresh DM build) never fast-paths.
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb.json', dm_spec: '/w/dm.json', artifacts: ALL_PRESENT)
check(d[:route] == :full && d[:reason] =~ /--dm-spec/,
      "--dm-spec present → :full (got #{d[:route]})", fails)

# 6. Artifacts missing, NO --yes → FULL (fall back to discovery).
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb.json', artifacts: NONE_PRESENT, yes: false)
check(d[:route] == :full && d[:degraded].size == 3 && d[:reason] =~ /discovery/,
      "missing artifacts + no --yes → :full with reason naming discovery (got #{d[:route]})", fails)

# 7. Artifacts missing, WITH --yes → FAST but degraded, listing exactly what's missing.
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb.json', artifacts: NONE_PRESENT, yes: true)
check(d[:route] == :fast && d[:degraded].sort == NONE_PRESENT.keys.sort,
      "missing artifacts + --yes → :fast DEGRADED, lists all missing (got #{d[:route]}, #{d[:degraded]})", fails)

# 8. --finalize never fast-paths (pass 2 resumes from migrate-state.json).
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb.json', finalize: true, artifacts: ALL_PRESENT)
check(d[:route] == :full && d[:reason] =~ /finalize/,
      "--finalize → :full (got #{d[:route]})", fails)

# 9. Partial artifacts + --yes → degraded names ONLY the missing one.
partial = ALL_PRESENT.merge('views/*.csv' => false)
d = FastPath.decide(reuse_dm: 'dm-abc123', wb_spec: '/w/wb.json', artifacts: partial, yes: true)
check(d[:route] == :fast && d[:degraded] == ['views/*.csv'],
      "one artifact missing + --yes → :fast, degraded names it (got #{d[:degraded]})", fails)

# 10. Empty/blank id is not an explicit id.
d = FastPath.decide(reuse_dm: '  ', wb_spec: '/w/wb.json', artifacts: ALL_PRESENT)
check(d[:route] == :full, "blank --reuse-dm id → :full (got #{d[:route]})", fails)

puts '— read_json_utf8(): BOM tolerance —'

Dir.mktmpdir do |d|
  payload = { 'pages' => [{ 'name' => 'Página', 'elements' => [] }] }
  bom = File.join(d, 'bom.json')
  File.binwrite(bom, "\xEF\xBB\xBF" + JSON.pretty_generate(payload))
  parsed = begin
    FastPath.read_json_utf8(bom)
  rescue StandardError => e
    e
  end
  check(parsed == payload, "UTF-8-BOM'd JSON (PowerShell Set-Content) parses (got #{parsed.class})", fails)

  crlf = File.join(d, 'bom-crlf.json')
  File.binwrite(crlf, "\xEF\xBB\xBF" + JSON.pretty_generate(payload).gsub("\n", "\r\n"))
  parsed = (FastPath.read_json_utf8(crlf) rescue nil)
  check(parsed == payload, 'BOM + CRLF line endings parse', fails)

  plain = File.join(d, 'plain.json')
  File.binwrite(plain, JSON.generate(payload))
  parsed = (FastPath.read_json_utf8(plain) rescue nil)
  check(parsed == payload, 'plain (BOM-less) JSON still parses', fails)
end

puts '— migrate-tableau.rb flag parsing (--help) —'

# force UTF-8: --help text is UTF-8 prose; with LANG/LC_ALL unset the popen
# read comes back US-ASCII and the =~ checks below crash on a non-UTF-8 locale
out = IO.popen(['ruby', MIGRATE, '--help'], err: %i[child out], &:read).force_encoding('UTF-8')
st = $?.exitstatus
check(st.zero?, "--help exits 0 (got #{st})", fails)
check(out.include?('FAST PATH'), '--help documents the FAST PATH semantics', fails)
%w[--reuse-dm --wb-spec --dm-spec].each do |flag|
  check(out.include?(flag), "--help lists #{flag}", fails)
end
check(out =~ /--yes proceeds DEGRADED|never re-run under --yes/,
      '--help states the --yes degraded semantics', fails)

ok = system('ruby', '-c', MIGRATE, out: File::NULL, err: File::NULL)
check(ok, 'migrate-tableau.rb parses clean (ruby -c)', fails)

puts
if fails.empty?
  puts "OK — all #{File.foreach(__FILE__).count { |l| l.include?('check(') } - 1} fast-path checks passed"
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
