#!/usr/bin/env ruby
# frozen_string_literal: true
# POST or PUT an Omni-converted Sigma data model spec and read it back
# (Gate C5: server-assigned element IDs replace authoring IDs before workbook build).
#
#   ruby scripts/post-omni-dm.rb --spec dm.json --mode dm-mode.json --out dm-elements.json

require 'optparse'
require 'json'
require_relative 'lib/sigma_rest'

def unwrap_dm_spec(raw)
  raw.is_a?(Hash) && raw['sigmaDataModel'].is_a?(Hash) ? raw['sigmaDataModel'] : raw
end

def post_or_put_dm(authored, dm_mode)
  if dm_mode.is_a?(Hash) && dm_mode['mode'] == 'extend'
    dm_id = dm_mode.fetch('dataModelId')
    Sigma.request(:put, "/v2/dataModels/#{dm_id}/spec", body: authored.to_json)
    dm_id
  else
    posted = Sigma.request(:post, '/v2/dataModels/spec', body: authored.to_json)
    posted.fetch('dataModelId') { raise "POST /v2/dataModels/spec did not return dataModelId: #{posted.inspect}" }
  end
end

def columns_for_lookup(authored_el, live_el)
  authored_cols = authored_el['columns'] || []
  live_cols = live_el['columns'] || []
  authored_cols.each_with_index.map do |ac, i|
    live_name = live_cols[i].is_a?(Hash) ? live_cols[i]['name'] : nil
    { 'id' => ac['id'], 'name' => live_name || ac['name'] }
  end
end

def element_lookup_from_readback(readback_spec, authored_elements, data_model_id:)
  live_elements = readback_spec.dig('pages', 0, 'elements') || []
  authored_elements.each_with_index.each_with_object({}) do |(authored_el, i), acc|
    live_el = live_elements[i] || authored_el
    key = authored_el['id'].to_s.sub(/\Ael-/, '')
    acc[key] = {
      'id' => key,
      'dataModelId' => data_model_id,
      'elementId' => live_el['id'],
      'name' => live_el['name'] || authored_el['name'],
      'columns' => columns_for_lookup(authored_el, live_el)
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--spec PATH') { |v| opts[:spec] = v }
    o.on('--mode PATH') { |v| opts[:mode] = v }
    o.on('--out PATH')  { |v| opts[:out] = v }
  end.parse!(ARGV)
  { spec: '--spec', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end

  raw = JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))
  authored = unwrap_dm_spec(raw)
  dm_mode = if opts[:mode] && File.file?(opts[:mode])
              JSON.parse(File.read(opts[:mode], encoding: 'UTF-8'))
            else
              { 'mode' => 'create' }
            end
  authored_elements = authored.dig('pages', 0, 'elements') || []

  dm_id = post_or_put_dm(authored, dm_mode)
  readback = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
  lookup = element_lookup_from_readback(readback, authored_elements, data_model_id: dm_id)
  File.write(opts[:out], JSON.pretty_generate(lookup) + "\n")
  warn "#{dm_mode['mode'] == 'extend' ? 'extended' : 'posted'} data model #{dm_id}, wrote #{opts[:out]}"
end
