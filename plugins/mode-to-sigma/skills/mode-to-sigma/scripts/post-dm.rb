#!/usr/bin/env ruby
# POST dm-spec.json, then GET it back to learn server-assigned element ids
# (ids in the authored spec are never the real ones — this is C5, a hard
# gate: no workbook-building step may run before this).
#
#   ruby scripts/post-dm.rb --spec dm-spec.json --mode dm-mode.json --out dm-elements.json
require 'optparse'
require 'json'
require_relative 'lib/sigma_rest'

# {"mode"=>"create"} -> POST (new DM). {"mode"=>"extend","dataModelId"=>id} ->
# PUT that exact DM (Task 5's reuse-check already picked it) so C3's whole
# point — avoid DM sprawl — isn't defeated by always creating a new one.
#
# body: authored.to_json (not the bare Hash) — matches every sibling
# converter's own Sigma.request(:post/:put, ..., body: spec.to_json) convention
# (see e.g. hex-to-sigma/scripts/post-and-readback.rb and this repo's own
# lib/sigma_rest.rb usage docstring). Sigma.request's `body` is written
# verbatim as the HTTP request body — a raw Hash there would send Ruby's
# `Hash#to_s` (`{"name"=>"x"}`, not JSON) and Sigma would 400 on every real run.
def post_or_put_dm(authored, dm_mode)
  if dm_mode['mode'] == 'extend'
    dm_id = dm_mode.fetch('dataModelId')
    Sigma.request(:put, "/v2/dataModels/#{dm_id}/spec", body: authored.to_json)
    dm_id
  else
    posted = Sigma.request(:post, '/v2/dataModels/spec', body: authored.to_json)
    posted.fetch('dataModelId') { raise "POST /v2/dataModels/spec did not return dataModelId: #{posted.inspect}" }
  end
end

# Positionally pairs each AUTHORED column (build-dm.rb's own
# `"#{token}_#{raw_column}"` ids, in authoring order) with its server-readback
# counterpart column (same order Sigma preserves elements in — see
# element_lookup_from_readback above), producing
# `[{"id" => <raw SQL column, i.e. token-prefix stripped>, "name" => <the
# DISPLAY name Sigma actually persisted>}, ...]`. This is the ONLY place a raw
# field name -> DM display name mapping is available for
# build-mode-workbook.rb's chart column binding to look up (dm-elements.json,
# Task 6's own output, previously carried no per-column info at all — a chart
# formula referencing a raw field name like `order_month` is wrong once
# build-dm.rb's `title_case` has renamed that column's DISPLAY name to
# "Order Month"; Sigma resolves cross-element column references by name, not
# by raw SQL alias). Falls back to the authored name if the live readback is
# ever missing that position (defensive; should not happen in practice).
def columns_for_lookup(authored_el, live_el, token)
  authored_cols = authored_el['columns'] || []
  live_cols = live_el['columns'] || []
  authored_cols.each_with_index.map do |ac, i|
    raw = ac['id'].to_s.sub(/\A#{Regexp.escape(token)}_/, '')
    live_name = live_cols[i].is_a?(Hash) ? live_cols[i]['name'] : nil
    { 'id' => raw, 'name' => live_name || ac['name'] }
  end
end

# original_ids: {query_token => authoring_element_id}; spec: the GET-back spec.
# Server assigns elements in the SAME ORDER they were authored, so pair positionally.
def element_lookup_from_readback(spec, original_ids, authored_elements, data_model_id:)
  ordered_tokens = original_ids.keys # insertion order == authoring order
  live_elements = spec['pages'].first['elements']
  ordered_tokens.each_with_index.each_with_object({}) do |(token, i), acc|
    el = live_elements[i]
    authored_el = authored_elements[i]
    acc[token] = { 'dataModelId' => data_model_id, 'elementId' => el['id'], 'name' => el['name'],
                   'columns' => columns_for_lookup(authored_el, el, token) }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--spec PATH') { |v| opts[:spec] = v }
    o.on('--mode PATH') { |v| opts[:mode] = v }
    o.on('--out PATH')  { |v| opts[:out] = v }
  end.parse!(ARGV)

  authored = JSON.parse(File.read(opts[:spec]))
  dm_mode = JSON.parse(File.read(opts[:mode]))
  authored_elements = authored['pages'].first['elements']
  original_ids = authored_elements.each_with_object({}) do |el, acc|
    acc[el['id'].sub(/\Ael-/, '')] = el['id']
  end

  dm_id = post_or_put_dm(authored, dm_mode)

  readback = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
  lookup = element_lookup_from_readback(readback, original_ids, authored_elements, data_model_id: dm_id)
  File.write(opts[:out], JSON.pretty_generate(lookup))
  warn "#{dm_mode['mode'] == 'extend' ? 'extended' : 'posted'} data model #{dm_id}, wrote #{opts[:out]}"
end
