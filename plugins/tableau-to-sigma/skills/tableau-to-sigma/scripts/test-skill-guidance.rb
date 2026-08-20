#!/usr/bin/env ruby
# frozen_string_literal: true

# Keep phase guidance and generated scanner output aligned with the proven
# Custom SQL modeling policy and governed metric namespace.

root = File.expand_path('..', __dir__)
files = {
  phase1: File.read(File.join(root, 'refs', 'phase-1-discover.md'), encoding: 'UTF-8'),
  phase3: File.read(File.join(root, 'refs', 'phase-3-datamodel.md'), encoding: 'UTF-8'),
  enhance: File.read(File.join(root, 'refs', 'phase-e-enhance.md'), encoding: 'UTF-8'),
  coverage: File.read(File.join(root, 'refs', 'coverage-matrix.md'), encoding: 'UTF-8'),
  migrate: File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8'),
  gaps: File.read(File.join(__dir__, 'scan-workbook-gaps.rb'), encoding: 'UTF-8'),
  enhance_scan: File.read(File.join(__dir__, 'enhance-scan.rb'), encoding: 'UTF-8')
}

failures = []
check = lambda do |condition, message|
  failures << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

puts 'Custom SQL modeling guidance'
check.call(files[:phase1].include?('prefer warehouse-table'),
           'discovery treats Custom SQL as inventory and prefers equivalent tables')
check.call(files[:coverage].include?('warehouse-table model when equivalent'),
           'coverage matrix records the conditional table-first policy')
check.call(files[:gaps].include?('prefer equivalent warehouse-table elements'),
           'gap scanner reports the conditional table-first policy')
check.call(!files[:phase1].include?('not warehouse-table references'),
           'discovery no longer mandates Custom SQL elements')
check.call(!files[:migrate].include?('the DM element must use source.kind=sql'),
           'orchestrator checkpoint does not mandate source.kind=sql')

puts 'Governed metric guidance'
check.call(files[:phase3].include?('[Metrics/<metric name>]'),
           'Phase 3 documents the governed metric namespace')
check.call(files[:enhance].include?('[Metrics/<metric name>]'),
           'enhancement guidance points to normal metric binding')
check.call(!files[:enhance].include?("metric refs don't resolve"),
           'enhancement guidance does not claim metrics are unsupported')
check.call(!files[:enhance_scan].include?('descoped-dm-metric-promotion'),
           'enhancement scanner does not emit an obsolete metric warning')

if failures.empty?
  puts 'ALL PASS - Tableau modeling and metric guidance are consistent'
  exit 0
end

warn "#{failures.size} failure(s):\n  - #{failures.join("\n  - ")}"
exit 1
