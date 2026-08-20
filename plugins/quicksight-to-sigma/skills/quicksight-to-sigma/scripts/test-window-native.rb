#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-window-native.rb — regression for the safe inline QuickSight window-fn →
# native Sigma mapping ([bead]). Guards the invariant:
#
#   SELF-CONTAINED windows (unpartitioned rank / denseRank / percentileRank +
#   unpartitioned percentOfTotal) map to a native Sigma window fn — they fully
#   specify their own ordering/scope, so they resolve faithfully in a calc column
#   (live-verified 2026-07-15).
#
#   Order/partition-DEPENDENT windows (running*/lag/lead/difference/period*/
#   window*/*Over), PARTITIONED rank/percentOfTotal, and NESTED window exprs must
#   still degrade to Null — mapping them inline would silently drop the
#   QuickSight PARTITION BY / ORDER BY (native fns inherit the element's grain).
#
# Creds-free, network-free. Shells to node (preinstalled on the CI runner).

require 'open3'
require 'json'

conv = File.expand_path('../converter/quicksight.mjs', __dir__)
abort "converter not found: #{conv}" unless File.exist?(conv)

node_script = <<~JS
  const { quicksightFormulaToSigma } = await import(#{"file://#{conv}".to_json});
  const cases = [
    // [expr, expectation, optional shape regex]
    ["rank([sum({Sales}) DESC])",        "map",  /^Rank\\(Sum\\(\\[Sales\\]\\), "desc"\\)$/],
    ["rank([sum({Sales})])",             "map",  /"desc"\\)$/],
    ["denseRank([sum({Profit}) ASC])",   "map",  /^RankDense\\(.*"asc"\\)$/],
    ["percentileRank([sum({X})])",       "map",  /^RankPercentile\\(.*"asc"\\)$/],
    ["percentOfTotal(sum({Sales}))",     "map",  /^PercentOfTotal\\(.*"grand_total"\\)$/],
    ["runningSum(sum({Sales}), [{OrderDate} ASC])", "null"],
    ["rank([sum({Sales}) DESC], [{Region}])",       "null"],
    ["percentOfTotal(sum({Sales}), [{Region}])",    "null"],
    ["sumOver(sum({Sales}), [{Region}])",           "null"],
    ["lag(sum({Sales}), [{OrderDate} ASC], 1)",     "null"],
    ["rank([sum({Sales})]) + 1",                    "null"],
  ];
  let fail = 0;
  for (const [expr, want, re] of cases) {
    const out = quicksightFormulaToSigma(expr, []);
    const isNull = out === "Null";
    const ok = want === "null" ? isNull : (!isNull && (!re || re.test(out)));
    if (!ok) { fail++; console.error(`  FAIL [${want}] ${expr}  =>  ${out}`); }
  }
  process.exit(fail === 0 ? 0 : 1);
JS

out, status = Open3.capture2e('node', '--input-type=module', stdin_data: node_script)
if status.success?
  puts 'PASS: QuickSight safe-window → native mapping (11 cases; self-contained map, order/partition-dependent degrade)'
  exit 0
else
  warn out
  warn 'FAIL: test-window-native.rb — window-fn mapping regression'
  exit 1
end
