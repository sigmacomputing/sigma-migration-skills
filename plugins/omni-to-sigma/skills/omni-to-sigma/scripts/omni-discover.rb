#!/usr/bin/env ruby
# frozen_string_literal: true
# Discover an Omni dashboard + semantic model YAML via REST API (or probe
# credentials). Unpacks GET /api/v1/models/{modelId}/yaml?mode=combined into a
# local model directory that convert-dm.rb and detect-rls.rb can consume.
#
#   ruby scripts/omni-discover.rb --probe
#   ruby scripts/omni-discover.rb --document <doc-id> [--model-id <id>] [--out-dir discovery]

require 'optparse'
require 'json'
require 'fileutils'
require_relative 'lib/omni_rest'
require_relative 'lib/omni_export'

OUT = ENV['OMNI_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

def extract_yaml_files(resp)
  return {} unless resp.is_a?(Hash)
  files = resp['files']
  return files if files.is_a?(Hash)
  data_files = resp.dig('data', 'files')
  return data_files if data_files.is_a?(Hash)
  {}
end

def unpack_model_yaml(files_hash, model_dir)
  FileUtils.mkdir_p(model_dir)
  written = []
  files_hash.each do |rel_path, content|
    clean_rel = rel_path.to_s.sub(%r{\A/+}, '')
    next if clean_rel.empty? || clean_rel.include?('..')
    dest = File.join(model_dir, clean_rel)
    FileUtils.mkdir_p(File.dirname(dest))
    text = if content.is_a?(Hash)
             (content['content'] || content['yaml'] || content['raw']).to_s
           else
             content.to_s
           end
    File.write(dest, text)
    written << clean_rel
  end
  written.sort
end

def infer_model_id_and_topic(export_doc)
  norm = OmniExport.normalize(export_doc)
  tiles = norm['tiles'] || []
  model_id = export_doc.dig('document', 'modelId') ||
             export_doc.dig('dashboard', 'modelId') ||
             export_doc['modelId']
  topic = nil
  tiles.each do |t|
    q = t['query'].is_a?(Hash) ? t['query'] : {}
    model_id ||= q['modelId']
    topic ||= t['topic'] || q['join_paths_from_topic_name'] || q['table']
  end
  [model_id, topic]
end

if __FILE__ == $PROGRAM_NAME
  opts = { out_dir: OUT }
  OptionParser.new do |o|
    o.on('--probe') { opts[:probe] = true }
    o.on('--document ID') { |v| opts[:document] = v }
    o.on('--model-id ID') { |v| opts[:model_id] = v }
    o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
  end.parse!(ARGV)

  if opts[:probe]
    models_resp = OmniRest.get('/api/v1/models', query: { 'modelKind' => 'SHARED' })
    models = models_resp['records'] || models_resp['models'] || []
    docs_resp = OmniRest.get('/api/v1/documents')
    docs = docs_resp['records'] || docs_resp['documents'] || []
    warn "Omni probe OK: #{models.length} shared model(s), #{docs.length} document(s)"
    exit 0
  end

  abort 'missing --document' if opts[:document].to_s.empty?
  out_dir = File.expand_path(opts[:out_dir])
  FileUtils.mkdir_p(out_dir)

  export_doc = OmniRest.get("/api/unstable/documents/#{opts[:document]}/export")
  export_path = File.join(out_dir, 'dashboard-export.json')
  File.write(export_path, JSON.pretty_generate(export_doc) + "\n")

  inferred_model_id, inferred_topic = infer_model_id_and_topic(export_doc)
  model_id = opts[:model_id] || inferred_model_id
  model_dir = File.join(out_dir, 'model')
  written_files = []

  if model_id && !model_id.to_s.empty?
    yaml_resp = OmniRest.get("/api/v1/models/#{model_id}/yaml", query: { 'mode' => 'combined' })
    files_hash = extract_yaml_files(yaml_resp)
    written_files = unpack_model_yaml(files_hash, model_dir)
  end

  manifest = {
    'document_id' => opts[:document],
    'model_id' => model_id,
    'topic' => inferred_topic,
    'export_path' => export_path,
    'model_dir' => model_dir,
    'yaml_files' => written_files
  }
  manifest_path = File.join(out_dir, 'manifest.json')
  File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  warn "discovered document #{opts[:document]} (model=#{model_id || 'none'}, topic=#{inferred_topic || 'unknown'}, #{written_files.length} yaml files)"
end
