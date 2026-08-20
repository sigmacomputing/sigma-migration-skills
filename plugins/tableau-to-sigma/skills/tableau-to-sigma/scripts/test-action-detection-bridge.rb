#!/usr/bin/env ruby
# Regression test for the DETECTION → EMISSION bridge between
# build-postpublish-guide.rb (owns detection: extract_nav_actions,
# extract_parameter_actions, extract_buttons, ...) and
# build-charts-from-signals.rb (owns emission: writes actions[] onto elements).
# Before this bridge the two scripts could not talk to each other, so
# nav-action mark clicks and parameter actions had no path to ever be
# auto-wired — build-charts-from-signals.rb never saw what the .twb parse
# detected.
#
# This test proves the bridge carries REAL data end to end, not just that a
# flag is accepted:
#
#   1. `build-postpublish-guide.rb --detect-only PATH` runs the actual .twb
#      detection and writes the raw detected-entries ARRAY to PATH — and
#      does NOT render POSTPUBLISH_GUIDE.md and does NOT write
#      action-ledger.json (or anything ledger-shaped). That second part
#      matters structurally: a later gate reads <workdir>/action-ledger.json
#      and asserts conservation over it; an early half-ledger with
#      `emitted: []` would be read as "nothing was ever auto-wired" — exactly
#      the failure mode the bridge must avoid.
#   2. `build-charts-from-signals.rb --detected-actions PATH` loads that SAME
#      array (produced by step 1, not re-derived by this test) and reports
#      how many entries it parsed via an observable `warn` line — proof the
#      chart build actually received and parsed the detected actions.
#   3. Omitting --detected-actions is fully backward-compatible: the build
#      still runs and reports 0 loaded.
#
# Deterministic + offline: drives the ACTUAL CLIs against the committed
# scripts/test-fixtures/postpublish-actions.twb (the same fixture
# test-postpublish-guide.rb uses) — no live creds, no customer data.
#
# Usage:  ruby scripts/test-action-detection-bridge.rb

require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
PARSER  = File.join(DIR, 'parse-twb-layout.rb')
BUILD   = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  puts '== Part 1: build-postpublish-guide.rb --detect-only ======================'
  detect_out = File.join(d, 'detected-actions.json')
  guide_out  = File.join(d, 'POSTPUBLISH_GUIDE.md')
  ledger_out = File.join(d, 'action-ledger.json')

  log1, st1 = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detect_out)
  check(st1.success?, "--detect-only exits 0 (got #{st1.exitstatus}); output:\n#{log1}")
  check(File.exist?(detect_out), '--detect-only wrote its output file')
  check(!File.exist?(guide_out), '--detect-only did NOT render POSTPUBLISH_GUIDE.md (no --out was even given)')
  check(!File.exist?(ledger_out),
        '--detect-only did NOT write action-ledger.json — no ledger-shaped output at all, ' \
        'so a later gate can never mistake an early half-ledger for the authoritative one')

  detected = nil
  if File.exist?(detect_out)
    begin
      detected = JSON.parse(File.read(detect_out, encoding: 'UTF-8'))
    rescue JSON::ParserError => e
      check(false, "--detect-only output is valid JSON (#{e.message})")
    end
  end

  check(detected.is_a?(Array),
        "--detect-only output is a bare entries ARRAY, not a ledger object " \
        "(got #{detected.class}#{detected.is_a?(Hash) ? " with keys #{detected.keys.inspect}" : ''})")
  detected = [] unless detected.is_a?(Array)
  check(!detected.empty?, "--detect-only output is non-empty (got #{detected.length} entries)")

  by_kind = detected.group_by { |e| e.is_a?(Hash) ? e['kind'] : nil }
  # Same fixture, same expected shape test-postpublish-guide.rb already locks —
  # reused here to prove this is genuine detected content, not a stub.
  expected_counts = {
    'filter-action' => 1, 'highlight-action' => 1, 'url-action' => 1,
    'nav-action' => 1, 'parameter-action' => 1, 'set-action' => 1,
    'drill-hierarchy' => 1, 'custom-tooltip' => 2,
    'show-hide-button' => 1, 'export-button' => 1, 'nav-button' => 1
  }
  expected_counts.each do |kind, n|
    check((by_kind[kind] || []).length == n, "detect-only finds #{n} #{kind} (got #{(by_kind[kind] || []).length})")
  end
  total_expected = expected_counts.values.reduce(:+)
  check(detected.length == total_expected, "detect-only total == #{total_expected} (got #{detected.length})")

  check(detected.all? { |e| e.is_a?(Hash) && e.key?('kind') && e.key?('caption') },
        'every detected entry carries kind + caption')

  # Not every kind carries a Tableau actionName (drill-paths/tooltips have no
  # <action> element at all — see action_ledger.rb's key_of comment) — but
  # every kind that DOES (the ones ActionLedger.join actually needs to
  # disambiguate) must carry a real, non-empty one.
  action_name_kinds = %w[filter-action highlight-action url-action nav-action
                         parameter-action set-action show-hide-button export-button nav-button]
  carriers = detected.select { |e| action_name_kinds.include?(e['kind']) }
  check(!carriers.empty? && carriers.all? { |e| e['actionName'].to_s != '' },
        "every entry of a kind that carries a Tableau action name has a non-empty actionName " \
        "(#{carriers.length} such entries, #{carriers.count { |e| e['actionName'].to_s != '' }} non-empty)")

  # A couple of resolved-content spot checks (not just counts) — proves the
  # SAME extraction logic (GUID/caption resolution, target expansion) ran.
  nav = (by_kind['nav-action'] || []).first || {}
  check(((nav['targets'] || []).first || {})['name'] == 'Detail Page',
        "nav-action target resolves to 'Detail Page' (got #{(nav['targets'] || []).inspect})")
  pa = (by_kind['parameter-action'] || []).first || {}
  check(pa['fields'] == ['Metric Button'],
        "parameter-action source field caption resolves to 'Metric Button' (got #{pa['fields'].inspect})")

  detected_count = detected.length

  puts
  puts '== Part 2: build-charts-from-signals.rb --detected-actions ================'
  layout = File.join(d, 'layout.json')
  meta   = File.join(d, 'layout-meta.json')
  unless system(RUBY, PARSER, FIXTURE, layout, out: File::NULL, err: File::NULL)
    check(false, 'parse-twb-layout.rb failed to build layout.json from the fixture (setup failure, not the bridge)')
  end

  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
                '(?i)^Region$'       => { 'id' => 'm-region',  'name' => 'Region' },
                '(?i)^Order ID$'     => { 'id' => 'm-orderid', 'name' => 'Order ID' },
                '(?i)^Category$'     => { 'id' => 'm-cat',     'name' => 'Category' },
                '(?i)^Sub-Category$' => { 'id' => 'm-subcat',  'name' => 'Sub-Category' },
                '(?i)^Product Name$' => { 'id' => 'm-prod',    'name' => 'Product Name' }
              ))
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
                'views' => { 'view' => [
                  { 'id' => 'v1', 'name' => 'Sales by Region' },
                  { 'id' => 'v2', 'name' => 'Region Detail' },
                  { 'id' => 'v3', 'name' => 'Metric Buttons' },
                  { 'id' => 'v4', 'name' => 'Filter Panel Sheet' }
                ] }
              ))
  Dir.mkdir(File.join(d, 'views'))
  %w[v1 v2 v3 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  # Phase 1d dashboard-read gate artifact — the build script refuses to build
  # without it. This test doesn't care about the chart content, only that the
  # build runs to completion and reports the --detected-actions load.
  File.write(File.join(d, 'png-read.json'), JSON.dump(
                'source_png' => 'views/v1.png',
                'tiles' => [
                  { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                  { 'title' => 'Region Detail',      'kind' => 'table' },
                  { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                  { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
                ],
                'text_elements' => [], 'filter_shelf' => []
              ))

  base_cmd = [RUBY, BUILD, '--tableau-dir', d, '--layout', layout, '--meta', meta,
              '--master-map', mmap, '--master-element-id', 'master']

  out_with = File.join(d, 'specs-with.json')
  log_with, st_with = Open3.capture2e(*base_cmd, '--detected-actions', detect_out, '--out', out_with)
  check(st_with.success?, "chart build WITH --detected-actions exits 0 (got #{st_with.exitstatus}); log:\n#{log_with}")
  check(log_with.include?("loaded #{detected_count} detected action(s)"),
        "chart build observably reports loading all #{detected_count} detected action(s) " \
        "(the SAME array --detect-only produced in Part 1, not a count this test invented) " \
        "— log line: #{(log_with[/^.*loaded \d+ detected action\(s\).*$/] || '(no matching line found)').strip.inspect}")

  puts
  puts '== Part 3: backward compatibility — omitting --detected-actions ==========='
  out_without = File.join(d, 'specs-without.json')
  log_without, st_without = Open3.capture2e(*base_cmd, '--out', out_without)
  check(st_without.success?,
        "chart build WITHOUT --detected-actions exits 0 (got #{st_without.exitstatus}); log:\n#{log_without}")
  check(log_without.include?('loaded 0 detected action(s)'),
        "chart build omitting --detected-actions still runs and reports 0 loaded (back-compat) " \
        "— log line: #{(log_without[/^.*loaded \d+ detected action\(s\).*$/] || '(no matching line found)').strip.inspect}")
end

puts
if $fails.empty?
  puts 'ALL PASS — detection (build-postpublish-guide.rb) → emission (build-charts-from-signals.rb) bridge carries real data'
else
  puts "#{$fails.length} FAILURE(S):"
  $fails.each { |f| puts "  - #{f}" }
end
exit($fails.empty? ? 0 : 1)
