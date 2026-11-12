#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Embedded-extract landing gate (exit 17) vs an explicit reused data model:
# lib/extract_landing_route.rb decides whether --reuse-dm <id> satisfies the
# gate, and the orchestrator wiring keeps the stop for fresh builds and for a
# reuse that is refused after the gate. Creds-free; the orchestrator part is a
# static check because driving its discovery path needs a live Tableau source.

require 'json'
require 'tmpdir'
require_relative 'lib/extract_landing_route'

HERE = File.expand_path(__dir__)

fails = []
check = lambda do |condition, message|
  fails << message unless condition
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
end

puts 'test-extract-landing-route — reuse decision'
Dir.mktmpdir('landroute') do |work|
  decide = lambda do |**kw|
    ExtractLandingRoute.reuse(workdir: work, **{ reuse_dm: 'dm-123', db: 'DB', schema: 'SCH', table_mapping: nil }.merge(kw))
  end

  r = decide.call
  check.(r[:satisfied] && r[:blocker].nil?, 'explicit --reuse-dm <id> + --db/--schema satisfies the gate')
  r = decide.call(db: nil, schema: nil, table_mapping: { 'Orders' => 'DB.SCH.ORDERS' })
  check.(r[:satisfied], 'explicit --reuse-dm <id> + --table-mapping satisfies the gate')
  r = decide.call(db: nil, schema: nil)
  check.(!r[:satisfied] && r[:blocker].to_s.include?('--db/--schema'),
         'explicit --reuse-dm <id> without --db/--schema or --table-mapping does not, and says why')
  r = decide.call(db: nil, schema: nil, table_mapping: {})
  check.(!r[:satisfied], 'an empty --table-mapping does not name any table')
  r = decide.call(db: 'DB', schema: ' ')
  check.(!r[:satisfied], 'a blank schema does not name the tables')
  r = decide.call(reuse_dm: nil)
  check.(!r[:satisfied] && r[:blocker].nil?, 'fresh build (no --reuse-dm): the gate keeps its stop, no reuse hint')
  r = decide.call(reuse_dm: :recommended)
  check.(!r[:satisfied] && r[:blocker].nil?, 'bare --reuse-dm (picker recommendation) is not an explicit reuse')
  File.write(File.join(work, 'posted-datamodels.jsonl'), "#{JSON.generate('id' => 'dm-123')}\n")
  r = decide.call
  check.(!r[:satisfied], 'a model this workdir posted itself (converter output over unlanded tables) does not')
end

puts 'test-extract-landing-route — after the reuse decision is final'
check.(!ExtractLandingRoute.stop_after_settle?(satisfied_by_reuse: true, reused: true),
       'reuse taken: no stop')
check.(ExtractLandingRoute.stop_after_settle?(satisfied_by_reuse: true, reused: false),
       'reuse refused after the gate: the landing stop fires before the fresh model is posted')
check.(!ExtractLandingRoute.stop_after_settle?(satisfied_by_reuse: false, reused: false),
       'gate satisfied another way (manifest / --skip-extract-landing): no deferred stop')

puts 'test-extract-landing-route — orchestrator wiring (static)'
src = File.read(File.join(HERE, 'migrate-tableau.rb'), encoding: 'UTF-8')
gate = src[src.index('embedded_classes = %w[')...src.index('conv_twb = twb')].to_s
check.(src.include?("require_relative 'lib/extract_landing_route'") || src.include?("'extract_landing_route'"),
       'migrate-tableau.rb loads lib/extract_landing_route')
check.(gate.include?('ExtractLandingRoute.reuse('), 'the landing gate asks ExtractLandingRoute.reuse')
reuse_at = gate.index('elsif landing_by_reuse')
skip_at = gate.index('elsif opts[:skip_extract_landing]')
check.(reuse_at && skip_at && reuse_at < skip_at,
       'an eligible reuse satisfies the gate before the --skip-extract-landing escape is consulted')
reuse_branch = reuse_at && skip_at ? gate[reuse_at...skip_at] : ''
check.(!reuse_branch.include?('Offramp.log') && !reuse_branch.include?('skip-flag-waived'),
       'the reuse branch records no escape (no off-ramp, no waiver)')
check.(gate.scan(/!opts\[:skip_extract_landing\] && !landing_by_reuse/).size >= 4,
       'auto-landing stands aside on the reuse route (no copies landed that would never be read)')
check.(gate.include?('extract_landing_required.call'), 'fresh builds still reach the EXTRACT LANDING REQUIRED stop')
settle_at = src.index('RelationshipRoute.settle(route: relationship_route')
phase3_post = src.index('if reuse_dm_id', settle_at.to_i)
settle_block = settle_at && phase3_post ? src[settle_at...phase3_post] : ''
check.(settle_block.include?('ExtractLandingRoute.stop_after_settle?(satisfied_by_reuse: landing_by_reuse') &&
       settle_block.include?('extract_landing_required.call'),
       'a refused reuse fires the deferred landing stop where the reuse decision is final (before Phase 3 POST)')
check.(src.include?("disc << '--no-extract-refetch' if opts[:skip_extract_landing]"),
       'the --skip-extract-landing live repoint still skips the extract re-download')
check.(src.match?(/disc << '--no-extract-refetch' if !opts\[:skip_extract_landing\] &&\s*ExtractLandingRoute\.reuse\(/),
       'the reuse route skips the extract re-download too (the bytes are never read)')

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
