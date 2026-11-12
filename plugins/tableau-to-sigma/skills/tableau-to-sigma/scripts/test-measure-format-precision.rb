#!/usr/bin/env ruby
# frozen_string_literal: true

# Plan C11b: measure number precision follows the SOURCE Tableau format.
# The builder is a run-on-load script, so its helpers are extracted from source
# and exercised directly (style of test-axis-title-sanitize.rb).

require 'json'
require_relative 'lib/format_map'
require_relative 'lib/measure_precision'
require_relative 'lib/null_member_display'

src = File.read(File.join(__dir__, 'build-charts-from-signals.rb'), encoding: 'UTF-8')
%w[tableau_format_to_sigma format_key_match_keys format_header_keys pick_tableau_format_raw
   pick_tableau_format pick_column_default_format_raw pick_column_default_format
   source_percent_format percent_override_format].each do |name|
  m = src.match(/^def #{name}\b.*?^end\n/m)
  abort "FAIL #{name} not found" unless m
  eval(m[0]) # rubocop:disable Security/Eval
end
COLUMN_DEFAULT_FORMATS = {}
FORMAT_KEY_CAPTIONS = {}

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# 1. Source 1dp percent beats the share override's 2dp default.
z = { 'formats' => { '[ds].[usr:Calc Share:qk]' => 'p0.0%' } }
fmt = percent_override_format(z, ',.2%', ['Calc Share'])
ok(fmt['formatString'] == ',.1%', 'source 1dp percent -> .1% (not the 2dp default)')

# 2. Source 0dp currency keeps 0dp.
fmt2 = FormatMap.translate('c"$"#,##0;("$"#,##0)')['formatString']
ok(fmt2 =~ /\$,\.0f|,\.0f/, 'source 0dp currency -> 0dp')

# 3. Source 0dp percent stays 0dp; 2dp percent stays 2dp.
ok(percent_override_format({ 'formats' => { '[x].[usr:S:qk]' => 'p0%' } }, ',.2%', ['S'])['formatString'] == ',.0%',
   'source 0dp percent -> 0dp')
ok(percent_override_format({ 'formats' => { '[x].[usr:S:qk]' => 'p0.00%' } }, ',.1%', ['S'])['formatString'] == ',.2%',
   'source 2dp percent -> 2dp')

# 4. .twb column default-format is a source too.
COLUMN_DEFAULT_FORMATS['Attain'] = 'p0.0%'
ok(percent_override_format({ 'formats' => {} }, ',.2%', ['Attain'])['formatString'] == ',.1%',
   'column default-format 1dp percent honoured')
COLUMN_DEFAULT_FORMATS.clear

# 5. No source format -> default unchanged.
ok(percent_override_format({ 'formats' => {} }, ',.2%', ['Nothing']) == { 'kind' => 'number', 'formatString' => ',.2%' },
   'no source format -> unchanged default')
ok(percent_override_format(nil, ',.1%', ['Nothing'])['formatString'] == ',.1%', 'nil zone -> unchanged default')

# 6. A non-percent source format (currency) never replaces a percent override.
zc = { 'formats' => { '[x].[usr:Rev Share:qk]' => 'c"$"#,##0' } }
ok(percent_override_format(zc, ',.1%', ['Rev Share'])['formatString'] == ',.1%',
   'currency source does not flip a share to currency')

# 7. displayNullAs preserved (existing column format, and C1 afterwards).
fmt3 = percent_override_format(z, ',.2%', ['Calc Share'], { 'kind' => 'number', 'formatString' => ',.0f', 'displayNullAs' => '' })
ok(fmt3['displayNullAs'] == '' && fmt3['formatString'] == ',.1%', 'existing displayNullAs preserved')
col = { 'id' => 'v', 'format' => percent_override_format(z, ',.2%', ['Calc Share']) }
NullMemberDisplay.merge_format!(col, { 'kind' => 'number', 'displayNullAs' => '' })
ok(col['format']['formatString'] == ',.1%' && col['format']['displayNullAs'] == '', 'C1 merge keeps the precision')

# 10. Repair loop (PercentOfTotal columns): nil format gets source percent format, else ,.1%;
#     source-derived 0dp percent is not re-rounded; a default ,.0% with no source is repaired.
loop_src = src[/^  cols_array\.each do \|c\|\n    next unless values_arr\.include\?\(c\['id'\]\)\n.*?^  end\n/m]
abort 'FAIL repair loop not found' unless loop_src
run_loop = lambda do |zz, fmt|
  c = { 'id' => 'v', 'name' => 'Share', 'formula' => 'PercentOfTotal(Sum([x]), "grand_total")' }
  c['format'] = fmt if fmt
  cols_array = [c]
  values_arr = ['v']
  z = zz
  eval(loop_src) # rubocop:disable Security/Eval
  c['format']
end
zsrc = { 'formats' => { '[ds].[usr:Share:qk]' => 'p0.00%' } }
ok(run_loop.call(zsrc, nil)['formatString'] == ',.2%', 'repair loop: nil format + source 2dp -> ,.2%')
ok(run_loop.call({ 'formats' => {} }, nil)['formatString'] == ',.1%', 'repair loop: nil format, no source -> ,.1%')
ok(run_loop.call({ 'formats' => { '[ds].[usr:Share:qk]' => 'p0%' } }, { 'kind' => 'number', 'formatString' => ',.0%' })['formatString'] == ',.0%',
   'repair loop: source 0dp percent not re-rounded')
ok(run_loop.call({ 'formats' => {} }, { 'kind' => 'number', 'formatString' => ',.0%' })['formatString'] == ',.1%',
   'repair loop: default ,.0% with no source -> ,.1%')

# 11. Multi-measure table fallback: source format wins over the label-regex guess.
fb = src[/^        fmt = pick_tableau_format\(z\['formats'\], label\).*?^                  \{ 'kind' => 'number', 'formatString' => ',\.0f' \}\n/m]
abort 'FAIL table fallback not found' unless fb
run_fb = lambda do |zz, label|
  z = zz
  base = label
  eval(fb) # rubocop:disable Security/Eval
  fmt
end
ok(run_fb.call({ 'formats' => { '[ds].[usr:Mix Share:qk]' => 'p0.00%' } }, 'Mix Share')['formatString'] == ',.2%',
   'table fallback: "...Share" with source p0.00% -> ,.2%')
ok(run_fb.call({ 'formats' => {} }, 'Mix Share')['formatString'] == ',.1%', 'table fallback: no source, share label -> ,.1% guess')
ok(run_fb.call({ 'formats' => {} }, 'Units')['formatString'] == ',.0f', 'table fallback: no source, plain label -> ,.0f')

# 9. Wiring: the hard-coded share/attainment overrides no longer clobber the source.
ok(src.scan("percent_override_format(z,").size >= 7, 'builder routes all percent overrides through the helper')
ok(src.scan(%r{= \{ 'kind' => 'number', 'formatString' => ',\.2%' \}}).empty?, 'no fixed 2dp percent assignment left')

if $fails.empty?
  puts 'ALL PASS'
else
  puts "FAILED: #{$fails.size}"
  exit 1
end
