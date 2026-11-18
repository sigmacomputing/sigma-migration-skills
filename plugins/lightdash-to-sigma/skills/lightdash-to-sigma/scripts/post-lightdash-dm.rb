#!/usr/bin/env ruby
# frozen_string_literal: true
# POST (or PUT, in extend mode) a Lightdash-converted Sigma data model spec and
# read it back. The readback is a mandatory gate: the live spec must contain the
# same elements, columns and metrics (paired by name) as the authored spec, otherwise
# the script exits 1 (the lookup file is still written for diagnosis).
#
#   ruby scripts/post-lightdash-dm.rb --spec dm.json [--mode dm-mode.json] --out dm-elements.json
#
# --spec accepts the convert-dm.rb envelope ({sigmaDataModel, stats, ...}) or a
# bare spec. dm-mode.json: {"mode":"extend","dataModelId":"..."} PUTs instead of
# POSTing; {"mode":"reuse","dataModelId":"..."} writes NOTHING and builds the lookup from the existing DM
# (authored items are paired to it by name; any missing is a gate failure). The --out lookup maps each authored element (id without the `el-`
# prefix) to the server-assigned element id plus per-column / per-metric ids, so
# the workbook builder can translate field-map.json ids to live ids.

require 'optparse'
require 'json'
require_relative 'lib/ruby_compat'
require_relative 'lib/sigma_rest'

module PostLightdashDm
  module_function

  def unwrap_dm_spec(raw)
    raw.is_a?(Hash) && raw['sigmaDataModel'].is_a?(Hash) ? raw['sigmaDataModel'] : raw
  end

  def elements_of(spec)
    spec.dig('pages', 0, 'elements') || spec['elements'] || []
  end

  # [{ id, name, columns, metrics }] for a spec (authored or live).
  def counts(spec)
    elements_of(spec).map do |el|
      { 'id' => el['id'], 'name' => el['name'], 'columns' => (el['columns'] || []).length,
        'metrics' => (el['metrics'] || []).length }
    end
  end

  # Pair authored items with live items BY NAME (the API does not promise order). Duplicate names
  # pair first-unused-first. Returns [[authored, live_or_nil], ...] in authored order.
  def pair_by_name(authored, live)
    pool = Array(live).select { |x| x.is_a?(Hash) }.dup
    Array(authored).map do |a|
      i = pool.index { |l| l['name'].to_s == a['name'].to_s }
      [a, i ? pool.delete_at(i) : nil]
    end
  end

  def error_typed?(col)
    col.is_a?(Hash) && (col['type'].to_s.downcase == 'error' || col.key?('error'))
  end

  # Returns an Array of mismatch strings (empty = gate passes). Elements, columns and metrics are paired
  # by NAME; a name authored but absent live is a mismatch, as is a count difference (exact mode) or an
  # error-typed live column (when the readback exposes types). exact: false is the reuse-an-existing-DM
  # mode: extra live items are fine (inherited), but everything authored must be present.
  def readback_mismatches(authored, live, stats: nil, exact: true)
    problems = []
    a = elements_of(authored)
    l = elements_of(live)
    problems << "element count: authored #{a.length}, live #{l.length}" if exact && a.length != l.length
    pair_by_name(a, l).each do |ae, le|
      next problems << "element #{ae['id']} (#{ae['name'].inspect}) missing from readback" unless le
      %w[columns metrics].each do |kind|
        a_n = (ae[kind] || []).length
        l_n = (le[kind] || []).length
        problems << "element #{ae['id']}: #{kind} authored #{a_n}, live #{l_n}" if exact && a_n != l_n
        pair_by_name(ae[kind], le[kind]).each do |ai, li|
          problems << "element #{ae['id']}: #{kind.chomp('s')} #{ai['name'].inspect} missing from readback" unless li
          problems << "element #{ae['id']}: #{kind.chomp('s')} #{ai['name'].inspect} is error-typed in the readback" if error_typed?(li)
        end
      end
    end
    if stats.is_a?(Hash)
      c = counts(authored)
      { 'elements' => c.length, 'columns' => c.sum { |e| e['columns'] }, 'metrics' => c.sum { |e| e['metrics'] } }.each do |k, v|
        problems << "envelope stats.#{k} is #{stats[k]}, spec has #{v}" if stats.key?(k) && stats[k] != v
      end
    end
    problems
  end

  def lookup_from_readback(readback, authored, data_model_id:)
    pair_by_name(elements_of(authored), elements_of(readback)).each_with_object({}) do |(ael, lel), acc|
      lel ||= ael
      key = ael['id'].to_s.sub(/\Ael-/, '')
      acc[key] = {
        'id' => key,
        'authoredId' => ael['id'],
        'dataModelId' => data_model_id,
        'elementId' => lel['id'],
        'name' => lel['name'] || ael['name'],
        'columns' => pair_up(ael['columns'], lel['columns']),
        'metrics' => pair_up(ael['metrics'], lel['metrics'])
      }
    end
  end

  def pair_up(authored, live)
    pair_by_name(authored, live).map do |ac, lc|
      lc ||= {}
      { 'id' => ac['id'], 'liveId' => lc['id'] || ac['id'], 'name' => lc['name'] || ac['name'] }
    end
  end

  # create: POST a new DM. extend: PUT into dataModelId. reuse: POST nothing; the existing DM is read back
  # and checked against the authored spec (nothing is written to Sigma).
  def post_or_put(authored, dm_mode)
    mode = dm_mode.is_a?(Hash) ? dm_mode['mode'].to_s : ''
    case mode
    when 'reuse'
      dm_mode.fetch('dataModelId')
    when 'extend'
      dm_id = dm_mode.fetch('dataModelId')
      Sigma.request(:put, "/v2/dataModels/#{dm_id}/spec", body: authored.to_json)
      dm_id
    else
      posted = Sigma.request(:post, '/v2/dataModels/spec', body: authored.to_json)
      posted.fetch('dataModelId') { raise "POST /v2/dataModels/spec did not return dataModelId: #{posted.inspect}" }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--spec PATH') { |v| opts[:spec] = v }
    o.on('--mode PATH') { |v| opts[:mode] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
  end.parse!(ARGV)
  { spec: '--spec', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end

  raw = JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))
  authored = PostLightdashDm.unwrap_dm_spec(raw)
  stats = raw.is_a?(Hash) && raw['sigmaDataModel'] ? raw['stats'] : nil
  dm_mode = if opts[:mode] && File.file?(opts[:mode])
              JSON.parse(File.read(opts[:mode], encoding: 'UTF-8'))
            else
              { 'mode' => 'create' }
            end

  dm_id = PostLightdashDm.post_or_put(authored, dm_mode)
  readback = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
  lookup = PostLightdashDm.lookup_from_readback(readback, authored, data_model_id: dm_id)
  File.write(opts[:out], JSON.pretty_generate(lookup) + "\n")
  verb = { 'extend' => 'extended', 'reuse' => 'reused (no write)' }.fetch(dm_mode['mode'].to_s, 'posted')
  problems = PostLightdashDm.readback_mismatches(authored, readback, stats: stats, exact: dm_mode['mode'].to_s != 'reuse')
  if problems.empty?
    warn "#{verb} data model #{dm_id}; readback verified (#{lookup.length} elements); wrote #{opts[:out]}"
  else
    warn "READBACK GATE FAILED for data model #{dm_id} (#{verb}):"
    problems.each { |p| warn "  - #{p}" }
    warn "lookup written to #{opts[:out]} for diagnosis; fix the spec and re-POST (do not build the workbook on this DM)"
    exit 1
  end
end
