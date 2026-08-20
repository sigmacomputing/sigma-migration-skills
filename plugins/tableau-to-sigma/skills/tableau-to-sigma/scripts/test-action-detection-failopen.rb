#!/usr/bin/env ruby
# A malformed .twb must NOT be indistinguishable from "this workbook has zero
# actions". Nokogiri's default recover mode returns a partial tree instead of
# raising, so before this test `--detect-only` on a truncated workbook exited 0
# and wrote `[]` — and migrate-tableau.rb ran it with allow_fail:true on top.
# Three layers of fail-open stacked on the same silent no-op.
#
# Deterministic + offline: drives the committed fixtures. No live creds.
#
# Usage:  ruby scripts/test-action-detection-failopen.rb
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR       = __dir__
GUIDE     = File.join(DIR, 'build-postpublish-guide.rb')
BAD       = File.join(DIR, 'test-fixtures', 'malformed.twb')
GOOD      = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
ORCH      = File.join(DIR, 'migrate-tableau.rb')
RUBY      = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  puts '== A malformed .twb fails LOUDLY ========================================='
  out = File.join(d, 'detected-actions.json')
  log, st = Open3.capture2e(RUBY, GUIDE, '--twb', BAD, '--detect-only', out)

  check(!st.success?,
        "--detect-only exits NON-zero on a malformed .twb (got #{st.exitstatus}) — " \
        'a recovered partial parse must not look like a successful one')
  check(!File.exist?(out),
        '--detect-only wrote NO output file on a malformed .twb — a partial or empty ' \
        'file would satisfy migrate-tableau.rb\'s File.exist? guard and be passed ' \
        'downstream as "zero actions"')
  check(log =~ /malformed|parse/i,
        "the failure message names the parse as the cause (got: #{log.lines.last.to_s.strip})")

  puts '== A well-formed .twb is UNCHANGED ======================================='
  good_out = File.join(d, 'good.json')
  log2, st2 = Open3.capture2e(RUBY, GUIDE, '--twb', GOOD, '--detect-only', good_out)
  check(st2.success?, "--detect-only still exits 0 on the good fixture; output:\n#{log2}")
  check(File.exist?(good_out), '--detect-only still writes its output file on the good fixture')
  entries = JSON.parse(File.read(good_out))
  check(entries.length == 12,
        "the good fixture still detects 12 interactions (got #{entries.length}) — " \
        'the strictness change must not alter detection results')

  puts '== The orchestrator no longer swallows detection failure ================='
  src = File.read(ORCH)
  # Anchor on the unique call-site text ("build-postpublish-guide.rb')," appears
  # exactly once in migrate-tableau.rb) and capture only up to the NEXT closing
  # paren — the one that closes this run! call. A looser regex here (matching
  # from the first *mention* of "build-postpublish-guide.rb" — there's an
  # earlier one in an unrelated advisory `puts` string — to the first
  # "--detect-only" anywhere after it) spans thousands of unrelated lines and
  # false-fails/false-passes on whichever `allow_fail: true` it happens to
  # sweep up from other run! calls in between.
  detect_call = src[/'build-postpublish-guide\.rb'\),.*?\)/m].to_s
  check(!detect_call.empty? && detect_call.include?('--detect-only'),
        'found the --detect-only call site in migrate-tableau.rb to check ' \
        "(matched: #{detect_call.inspect})")
  check(!detect_call.include?('allow_fail: true'),
        'migrate-tableau.rb runs --detect-only WITHOUT allow_fail: true ' \
        "(found: #{detect_call.lines.map(&:strip).join(' ')})")
end

puts
if $fails.empty?
  puts 'OK: detection cannot fail open'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
