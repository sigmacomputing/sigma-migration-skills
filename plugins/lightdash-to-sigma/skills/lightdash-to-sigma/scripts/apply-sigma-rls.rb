#!/usr/bin/env ruby
# frozen_string_literal: true
# Turn the detect-rls.rb plan into ordered Sigma steps. The row filter belongs on the DATA MODEL
# element (not the workbook), so every workbook built on the DM inherits it.
# Default is plan-only (no API writes, exit 0). --apply needs SIGMA_API_TOKEN (or any sign-in the
# shared client accepts) AND --confirm, and still creates nothing: user-attribute values are never
# invented, so it records `apply-ready` + acknowledged and leaves the attribute/filter creation to
# the human (same contract as omni-to-sigma/apply-sigma-rls.rb).
#
#   ruby scripts/apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json
#   ruby scripts/apply-sigma-rls.rb --plan rls-plan.json --out rls-steps.json --apply --confirm
#
# A plan whose untranslatable sql_filter(s) were waived (detect-rls.rb --ack --ack-complex REASON, recorded
# as acknowledged + ack_complex in the plan) is accepted: the translatable parts are still planned, and a
# `recorded-escape` degradation-ledger entry per waived filter is written to rls-gaps.json (and appended to
# chart-gaps.json when that file sits next to --out) so the final verdict cannot be GREEN.
#
# PENDING RLS: this script never creates the user attribute / data-model row filter / column security itself, so
# whenever the plan holds any (row_filters, column_security) it records a `skip-flag-waived` offramps.jsonl entry per
# planned step ("RLS planned, NOT applied"): the verdict derived by assert-phase6-ran is never GREEN until a human
# applied them and verified that a user with no attribute value sees no rows, then re-runs this script with
# `--applied "<who/how verified>"`, which clears the pending records and notes the evidence in rls-steps.json.
#
# Exit: 0 ok / plan-only / waived, 2 --apply refused (no token or no --confirm), 3 untranslated gaps, no waiver.

require 'json'
require 'optparse'
require_relative 'lib/degradation_ledger'
require_relative 'lib/lightdash_ledger'

module LightdashApplyRls
  module_function

  def steps(plan)
    out = []
    Array(plan['user_attributes']).each do |a|
      out << { 'step' => 'create-user-attribute', 'name' => a['name'],
               'sigma' => "Create Sigma user attribute #{a['name'].inspect} and assign it to each user/team that has the Lightdash attribute (mirror the Lightdash values; do not invent any)" }
    end
    Array(plan['row_filters']).each do |f|
      out << { 'step' => 'data-model-row-filter', 'element_id' => f['element_id'], 'column' => f['column'],
               'sigma' => "On the data model, add a row filter to element #{f['element_id']}: #{f['sigma'].to_s.sub(/\Adata-model row filter on [^:]+: /, '')}",
               'verify' => f['fail_closed'] }
    end
    Array(plan['column_security']).each do |c|
      out << { 'step' => 'column-security', 'target' => c['column_id'] || c['element_id'], 'sigma' => c['sigma'] }
    end
    out
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--plan PATH') { |v| opts[:plan] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--apply') { opts[:apply] = true }
    o.on('--confirm') { opts[:confirm] = true }
    o.on('--applied NOTE') { |v| opts[:applied] = v }
  end.parse!(ARGV)
  abort 'missing --plan' if opts[:plan].to_s.empty?
  abort 'missing --out' if opts[:out].to_s.empty?
  plan = JSON.parse(File.read(opts[:plan], encoding: 'UTF-8'))
  result = plan.merge('steps' => LightdashApplyRls.steps(plan))
  code = 0
  waived = Array(plan['gaps']).any? && plan['acknowledged'] && !plan['ack_complex'].to_s.strip.empty?
  if waived
    result['mode'] = 'waived'
    result['ledger_entries'] = plan['gaps'].map do |g|
      DegradationLedger.entry('recorded-escape', "RLS waived: #{g['item']}",
                              "row-level security NOT translated, waived by operator: #{plan['ack_complex']} (#{g['reason']})", 'apply-sigma-rls')
    end
    dir = File.dirname(File.expand_path(opts[:out]))
    File.write(File.join(dir, 'rls-gaps.json'), JSON.pretty_generate(result['ledger_entries']) + "\n")
    # The artifact the vendored DegradationLedger.derive / assert-phase6 verdict actually reads:
    # offramps.jsonl `skip-flag-waived` records become `recorded-escape` ledger entries (verdict never GREEN).
    trail = File.join(dir, 'offramps.jsonl')
    have = File.file?(trail) ? File.read(trail) : ''
    plan['gaps'].each do |g|
      rec = { 'kind' => 'skip-flag-waived', 'detail' => "RLS waived: #{g['item']}", 'reason' => plan['ack_complex'].to_s }
      File.open(trail, 'a') { |f| f.puts(JSON.generate(rec)) } unless have.include?(JSON.generate(rec))
    end
    cg = File.join(dir, 'chart-gaps.json')
    if File.file?(cg)
      cur = JSON.parse(File.read(cg, encoding: 'UTF-8'))
      if cur.is_a?(Array)
        File.write(cg, JSON.pretty_generate(cur + result['ledger_entries'].reject { |e| cur.include?(e) }) + "\n")
      elsif cur.is_a?(Hash) && cur['gaps'].is_a?(Array)
        cur['gaps'] += result['ledger_entries'].reject { |e| cur['gaps'].include?(e) }
        File.write(cg, JSON.pretty_generate(cur) + "\n")
      end
    end
  end
  if Array(plan['gaps']).any? && !waived
    result['mode'] = 'blocked'
    result['reason'] = 'untranslated sql_filter gap(s) in the plan; a human must decide before RLS can be applied'
    code = 3
  elsif opts[:apply]
    if ENV['SIGMA_API_TOKEN'].to_s.empty? || !opts[:confirm]
      result['mode'] = 'apply-refused'
      result['reason'] = 'live apply needs SIGMA_API_TOKEN and --confirm (user-attribute values are not invented)'
      code = 2
    else
      result['mode'] = 'apply-ready'
      result['acknowledged'] = true
      result['note'] = 'confirm recorded; creating the user attribute and the DM row filter is still manual -- this skill does not invent attribute values'
    end
  end
  # Pending (planned, not applied) RLS must reach the verdict ledger; --applied clears it with evidence.
  out_dir = File.dirname(File.expand_path(opts[:out]))
  planned = result['steps'].select { |st| %w[data-model-row-filter column-security].include?(st['step']) }
  if opts[:applied].to_s.strip.empty?
    recs = planned.map do |st|
      { 'kind' => 'skip-flag-waived', 'origin' => 'lightdash-rls-pending',
        'detail' => "RLS planned, NOT applied: #{st['step']} #{st['element_id'] || st['target']}".strip,
        'reason' => 'row/column security from the Lightdash model is only planned (rls-steps.json); apply it on the data model, verify ' \
                    'that a user with no attribute value sees no rows, then re-run apply-sigma-rls.rb with --applied "<evidence>"' }
    end
    LightdashLedger.replace_offramps(out_dir, 'lightdash-rls-pending', recs)
  else
    LightdashLedger.replace_offramps(out_dir, 'lightdash-rls-pending', [])
    result['applied_note'] = opts[:applied]
  end
  File.write(opts[:out], JSON.pretty_generate(result) + "\n")
  warn "wrote #{opts[:out]} (mode=#{result['mode']}, #{result['steps'].length} step(s))#{result['reason'] ? ": #{result['reason']}" : ''}"
  exit code
end
