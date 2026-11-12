#!/usr/bin/env ruby
# frozen_string_literal: true

# Turn the Phase-0 object graph into an executable, cardinality-aware target
# model plan. This command is offline; profiles are explicit evidence gathered
# by the operator or a warehouse probe and are never guessed.

require 'json'
require 'optparse'
require_relative 'lib/target_model_plan'

opts = { field_map: {}, table_map: {} }
OptionParser.new do |parser|
  parser.banner = 'usage: plan-target-model.rb --object-plan FILE --out FILE [options]'
  parser.on('--object-plan PATH') { |value| opts[:object_plan] = value }
  parser.on('--profiles PATH', 'optional warehouse table profiles JSON') { |value| opts[:profiles] = value }
  parser.on('--join-plan PATH', 'optional previously-probed join-plan.json evidence') { |value| opts[:join_plan] = value }
  parser.on('--field-map PAIR', 'TableauField=TargetField (repeatable)') do |value|
    key, target = value.split('=', 2)
    abort "invalid --field-map #{value.inspect}" if key.to_s.empty? || target.to_s.empty?
    opts[:field_map][key] = target
  end
  parser.on('--table-map PAIR', 'SourceTable=TargetTable (repeatable; requires proof in profiles)') do |value|
    key, target = value.split('=', 2)
    abort "invalid --table-map #{value.inspect}" if key.to_s.empty? || target.to_s.empty?
    opts[:table_map][key] = target
  end
  parser.on('--reuse-dm ID') { |value| opts[:reuse_dm_id] = value }
  parser.on('--accept ACTOR', 'accept a remodeled/reuse plan as ACTOR') { |value| opts[:accepted_by] = value }
  parser.on('--reason TEXT', 'required with --accept') { |value| opts[:reason] = value }
  parser.on('--out PATH') { |value| opts[:out] = value }
end.parse!

abort 'missing --object-plan' if opts[:object_plan].to_s.empty?
abort 'missing --out' if opts[:out].to_s.empty?
abort "not found: #{opts[:object_plan]}" unless File.exist?(opts[:object_plan])
abort "not found: #{opts[:profiles]}" if opts[:profiles] && !File.exist?(opts[:profiles])
abort "not found: #{opts[:join_plan]}" if opts[:join_plan] && !File.exist?(opts[:join_plan])

object_plan = JSON.parse(File.read(opts[:object_plan]))
profiles = opts[:profiles] ? JSON.parse(File.read(opts[:profiles])) : {}
plan = TargetModelPlan.build(
  object_plan,
  profiles: profiles,
  field_map: opts[:field_map],
  table_map: opts[:table_map],
  reuse_dm_id: opts[:reuse_dm_id],
  join_plan: opts[:join_plan] ? JSON.parse(File.read(opts[:join_plan])) : nil
)
if opts[:accepted_by]
  abort '--reason is required with --accept' if opts[:reason].to_s.strip.empty?
  TargetModelPlan.accept!(plan, accepted_by: opts[:accepted_by], reason: opts[:reason])
end

File.write(opts[:out], JSON.pretty_generate(plan) + "\n")
warn "wrote #{opts[:out]} (mode=#{plan['mode']}, accepted=#{plan['accepted']}, " \
     "required_proofs=#{plan['required_proofs'].size})"
