#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for scripts/lib/anchor_values.rb — the pure canonicalization core
# of the measured value bar (parse printed dashboard forms to (value, precision)
# pairs; a real number MATCHES when it rounds to the printed form at the
# printed precision). Offline, stdlib-only.
#
# Usage: ruby scripts/test-anchor-values.rb

require_relative 'lib/anchor_values'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def close(a, b, rel = 1e-9)
  (a - b).abs <= rel * [a.abs, b.abs, 1.0].max
end

puts '-- parse: canonical (value, tol, kind) per printed form --'
{
  # raw            =>  [value,        tol,      kind]
  '12,345B'        => [1.2345e13,     0.5e9,    'number'],
  '$1.8T'          => [1.8e12,        0.05e12,  'currency'],
  '46.5M'          => [4.65e7,        0.05e6,   'number'],
  '-2%'            => [-2.0,          0.5,      'percent'],
  '1,687'          => [1687.0,        0.5,      'number'],
  '$733,215.26'    => [733_215.26,    0.005,    'currency'],
  '(12.3%)'        => [-12.3,         0.05,     'percent'],
  '12.3k'          => [12_300.0,      50.0,     'number'],
  '$4,120'         => [4120.0,        0.5,      'currency'],
  '($4,120)'       => [-4120.0,       0.5,      'currency'],
  '0.5'            => [0.5,           0.05,     'number'],
  '.75'            => [0.75,          0.005,    'number'],
  '−3.1M'          => [-3.1e6,        0.05e6,   'number'],   # unicode minus
  '$-12.4'         => [-12.4,         0.05,     'currency'], # minus after symbol
  '99%'            => [99.0,          0.5,      'percent'],
  '7'              => [7.0,           0.5,      'number'],
  '2.05B'          => [2.05e9,        0.005e9,  'number'],
  '€1,2 34'.delete(' ') => [1234.0,   0.5,      'currency'] # € symbol + commas
}.each do |raw, (value, tol, kind)|
  p = AnchorValues.parse(raw)
  ok(!p.nil?, "#{raw.inspect} parses")
  next if p.nil?
  ok(close(p[:value], value), "#{raw.inspect} value #{p[:value]} == #{value}")
  ok(close(p[:tol], tol),     "#{raw.inspect} tol #{p[:tol]} == #{tol}")
  ok(p[:kind] == kind,        "#{raw.inspect} kind #{p[:kind]} == #{kind}")
end

puts '-- parse: rejects non-numbers --'
['', '  ', 'N/A', 'abc', '12abc', 'k', '$', '%', '--2', '1..2', nil, '1,2,3.4.5'].each do |raw|
  ok(AnchorValues.parse(raw).nil?, "#{raw.inspect} does not parse")
end

puts '-- match?: the printed-precision rounding rule --'
# "12,345B": tol ±0.5e9 → anything in [12,344.5B, 12,345.5B]
ok(AnchorValues.match?('12,345B', 12_345_000_000_000.0),  '12,345B matches 12.345e12 exactly')
ok(AnchorValues.match?('12,345B', 12_344_500_000_000.0),  '12,345B matches lower rounding bound')
ok(AnchorValues.match?('12,345B', 12_345_499_000_000.0),  '12,345B matches just under upper bound')
ok(!AnchorValues.match?('12,345B', 12_346_000_000_000.0), '12,345B rejects 12,346B')
ok(!AnchorValues.match?('12,345B', 1.2e12), 'THE FIELD FAILURE: 1.2T ($1.2T) does NOT match 12,345B (10x-off)')
ok(!AnchorValues.match?('12,345B', 1.2345e12), '12,345B rejects a clean 10x-down value')
ok(AnchorValues.match?('12,345B', 12_345.0), '12,345B matches the unscaled face value (column already in B)')
ok(!AnchorValues.match?('12,345B', 12_345.6), 'unscaled face value still honors printed precision')

# "$1.8T": tol ±0.05e12
ok(AnchorValues.match?('$1.8T', 1.8e12),   '$1.8T matches 1.8e12')
ok(AnchorValues.match?('$1.8T', 1.7501e12), '$1.8T matches 1.7501e12 (rounds to 1.8)')
ok(AnchorValues.match?('$1.8T', 1.849e12),  '$1.8T matches 1.849e12 (rounds to 1.8)')
ok(!AnchorValues.match?('$1.8T', 1.86e12),  '$1.8T rejects 1.86e12')
ok(!AnchorValues.match?('$1.2T', 1.2345e13), '$1.2T does NOT match the true 12,345B value')

# "46.5M": tol ±0.05e6
ok(AnchorValues.match?('46.5M', 46_500_000), '46.5M matches 46,500,000')
ok(AnchorValues.match?('46.5M', 46_460_000), '46.5M matches 46.46M (rounds to 46.5)')
ok(!AnchorValues.match?('46.5M', 46_560_000), '46.5M rejects 46.56M')
ok(AnchorValues.match?('46.5M', 46.5), '46.5M matches unscaled 46.5')

# percents: points AND fraction
ok(AnchorValues.match?('-2%', -2.0),    '-2% matches points form (-2)')
ok(AnchorValues.match?('-2%', -0.02),   '-2% matches fraction form (-0.02)')
ok(AnchorValues.match?('-2%', -0.0249), '-2% matches -2.49% as fraction (rounds to -2)')
ok(!AnchorValues.match?('-2%', 2.0),    '-2% rejects +2')
ok(!AnchorValues.match?('-2%', -0.03),  '-2% rejects -3% fraction')
ok(AnchorValues.match?('(12.3%)', -12.3),  '(12.3%) paren-negative matches -12.3 points')
ok(AnchorValues.match?('(12.3%)', -0.123), '(12.3%) matches -0.123 fraction')
ok(!AnchorValues.match?('(12.3%)', 12.3),  '(12.3%) rejects the positive value')

# plain / currency exact forms
ok(AnchorValues.match?('1,687', 1687),      '1,687 matches 1687')
ok(AnchorValues.match?('1,687', 1687.4),    '1,687 matches 1687.4 (rounds to 1687)')
ok(!AnchorValues.match?('1,687', 1688),     '1,687 rejects 1688')
ok(AnchorValues.match?('$733,215.26', 733_215.26),   'cents-precision currency matches exactly')
ok(AnchorValues.match?('$733,215.26', 733_215.2649), 'cents-precision tolerates sub-cent dust')
ok(!AnchorValues.match?('$733,215.26', 733_215.27),  'cents-precision rejects one cent off')
ok(AnchorValues.match?('12.3k', 12_300), '12.3k matches 12300')
ok(AnchorValues.match?('12.3k', 12_349), '12.3k matches 12349 (rounds to 12.3k)')
ok(!AnchorValues.match?('12.3k', 12_351), '12.3k rejects 12351')

puts '-- match?: non-numeric actuals never match --'
ok(!AnchorValues.match?('1,687', nil),    'nil actual never matches')
ok(!AnchorValues.match?('1,687', 'abc'),  'non-numeric actual never matches')
ok(AnchorValues.match?('1,687', '1687'),  'numeric STRING actual is coerced and matches')

puts '-- candidates / kind / relative_distance --'
ok(AnchorValues.candidates('bogus').empty?, 'unparseable raw yields no candidates')
ok(AnchorValues.candidates('12,345B').length == 2, 'suffixed form has scaled + unscaled candidates')
ok(AnchorValues.candidates('1,687').length == 1, 'plain integer has a single candidate')
ok(AnchorValues.candidates('-2%').length == 2, 'percent has points + fraction candidates')
ok(AnchorValues.kind('$5') == 'currency' && AnchorValues.kind('5%') == 'percent' &&
   AnchorValues.kind('5') == 'number', 'kind() maps to the schema enum')
ok(AnchorValues.kind('junk').nil?, 'kind() nil on unparseable')
d_near = AnchorValues.relative_distance('12,345B', 1.23e13)
d_far  = AnchorValues.relative_distance('12,345B', 1.2e12)
ok(d_near < d_far, 'relative_distance ranks the near value closer than the 10x-off value')
ok(AnchorValues.relative_distance('junk', 5).infinite?, 'relative_distance infinite on unparseable')

puts
if $fails.empty?
  puts 'ALL PASS — anchor_values canonicalization + printed-precision matching'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
