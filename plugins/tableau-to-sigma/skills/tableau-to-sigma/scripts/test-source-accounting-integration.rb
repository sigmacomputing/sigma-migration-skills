#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline wiring regression: the live orchestrator cannot be exercised without
# Tableau/Sigma credentials, so pin the source-accounting/report seams and their
# terminal ordering in the orchestrator source.

source = File.read(File.join(__dir__, 'migrate-tableau.rb'))
failures = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

preliminary = source.index("# Source accounting starts as soon as the required discovery facts exist.")
gap_gate = source.index('# GAP-SCAN HARD GATE')
check.call(preliminary && gap_gate && preliminary < gap_gate,
           'preliminary census runs after discovery artifacts and before the gap terminal')

final_census = source.index('# Refresh source accounting from the FINAL built/readback')
render_health = source.index('render_health_ok, render_health_note = refresh_render_health(WORK)')
report = source.index("['ruby', File.join(HERE, 'build-migration-report.rb'), '--workdir', WORK]")
result = source.index("puts '================ RESULT ================'", final_census || 0)
check.call(final_census && render_health && report && result &&
           final_census < render_health && render_health < report && report < result,
           'final census, render health, and migration report run before terminal result')

check.call(source.include?('accounting_ok = census_st.success? && report_st.success? && report_verdict != \'RED\'') &&
           source.include?('agst.success? && accounting_ok'),
           'RED/failed source accounting contributes to all_green=false')
check.call(source.include?("doc['render_health']") &&
           source.include?("File.join(work, 'sigma-render.png')") &&
           source.include?("File.join(HERE, 'png_health.py')"),
           'render health extracts visual similarity evidence or analyzes sigma-render.png')

puts
if failures.empty?
  puts 'ALL PASS'
else
  puts "#{failures.length} FAILURE(S)"
  failures.each { |failure| puts "  - #{failure}" }
  exit 1
end
