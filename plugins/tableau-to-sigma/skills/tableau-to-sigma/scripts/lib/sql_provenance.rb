# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'json'

# Account every data-model SQL element. Generated SQL is valid for Tableau
# LOD/window/Top-N/blend semantics, but it must never masquerade as a source
# table or appear without a deterministic reason.
module SqlProvenance
  ALLOWED_ORIGINS = %w[
    source-custom-sql generated-lod generated-top-n generated-window
    generated-blend generated-manual
  ].freeze

  module_function

  def record_active_spec(workdir, path, model_id)
    root = File.realpath(workdir)
    source = File.realpath(path)
    raise ArgumentError, 'active data-model spec must be inside the workdir' unless File.dirname(source) == root
    raise ArgumentError, 'active data-model id is missing' unless model_id.is_a?(String) && !model_id.empty?
    record = { 'path' => File.basename(source), 'data_model_id' => model_id,
               'sha256' => Digest::SHA256.file(source).hexdigest }
    destination = File.join(root, 'active-dm-spec.json')
    raise ArgumentError, 'active binding must not be a symlink' if File.symlink?(destination)
    File.open(destination, 'w', 0o600) { |file| file.write(JSON.pretty_generate(record)) }
  end

  def active_spec_path(workdir)
    binding = File.join(workdir, 'active-dm-spec.json')
    raise ArgumentError, 'active binding must not be a symlink' if File.symlink?(binding)
    if File.file?(binding)
      record = JSON.parse(File.read(binding))
      raise ArgumentError, 'invalid active data-model binding' unless record.is_a?(Hash) && record['data_model_id'].is_a?(String) && !record['data_model_id'].empty?
      name = record['path'].to_s
      raise ArgumentError, 'invalid active data-model spec path' if name.empty? || File.basename(name) != name || name.include?('\\')
      path = File.join(workdir, name)
      raise ArgumentError, 'active data-model spec is missing or stale' unless File.file?(path) && !File.symlink?(path) && Digest::SHA256.file(path).hexdigest == record['sha256']
      ids = JSON.parse(File.read(File.join(workdir, 'dm-ids.json')))
      raise ArgumentError, 'active data-model binding belongs to another model' unless ids.is_a?(Hash) && ids['dataModelId'] == record['data_model_id']
      return path
    end
    paths = %w[dm-spec.json dm-spec-reused.json dm-remapped.json dm-raw.json].map { |name| File.join(workdir, name) }.select { |path| File.file?(path) }
    raise ArgumentError, 'ambiguous data-model source; rerun the gated pass to record the active spec' if paths.size > 1
    paths.first
  end

  def normalize_sql(value)
    CGI.unescapeHTML(value.to_s)
       .sub(/\A\s*<!\[CDATA\[/, '').sub(/\]\]>\s*\z/, '')
       .gsub(/\s+/, ' ').strip.sub(/;\z/, '').downcase
  end

  def source_queries(twb_path, custom_sql_path = nil)
    queries = []
    if twb_path && File.file?(twb_path)
      raw = File.read(twb_path, encoding: 'bom|utf-8')
      raw.scan(%r{<relation\b(?=[^>]*\btype=['"]text['"])[^>]*>(.*?)</relation>}mi) do |match|
        queries << normalize_sql(match[0])
      end
    end
    if custom_sql_path && File.file?(custom_sql_path)
      doc = JSON.parse(File.read(custom_sql_path))
      walk = lambda do |value|
        case value
        when Hash
          %w[query sql statement].each { |key| queries << normalize_sql(value[key]) if value[key].is_a?(String) }
          value.each_value { |child| walk.call(child) if child.is_a?(Hash) || child.is_a?(Array) }
        when Array
          value.each { |child| walk.call(child) }
        end
      end
      walk.call(doc)
    end
    queries.reject(&:empty?).uniq
  end

  def evaluate(dm_spec_path:, metadata_path: nil, twb_path: nil, custom_sql_path: nil,
               overrides_path: nil)
    spec_raw = File.binread(dm_spec_path)
    spec = JSON.parse(spec_raw)
    metadata = metadata_path && File.file?(metadata_path) ? JSON.parse(File.read(metadata_path)) : {}
    source_sql = source_queries(twb_path, custom_sql_path)
    overrides = load_overrides(overrides_path)
    converter_entries = Array(metadata['sqlProvenance'])
    elements = Array(spec['pages']).flat_map { |page| Array(page['elements']) }
    sql_elements = elements.select { |element| element.dig('source', 'kind') == 'sql' }
    # Name matching only identifies an element whose name no other SQL element shares.
    name_counts = sql_elements.each_with_object(Hash.new(0)) { |element, counts| counts[element['name'].to_s] += 1 }

    entries = sql_elements.map do |element|
      statement = element.dig('source', 'statement').to_s
      normalized = normalize_sql(statement)
      unique_name = !element['name'].to_s.empty? && name_counts[element['name'].to_s] == 1
      converter_entry = converter_entries.find do |entry|
        entry.is_a?(Hash) && entry['elementId'].to_s == element['id'].to_s
      end
      # A live readback carries server-assigned ids; fall back to a unique
      # ledger name (the statement must still match below).
      if !converter_entry && unique_name
        named = converter_entries.select do |entry|
          entry.is_a?(Hash) && !entry['elementName'].to_s.empty? &&
            entry['elementName'].to_s == element['name'].to_s
        end
        converter_entry = named.first if named.size == 1
      end
      # A pass-1 override may be keyed by the converter id the readback lost.
      override = overrides[element['id'].to_s] ||
                 (unique_name && overrides[element['name'].to_s]) ||
                 (converter_entry && overrides[converter_entry['elementId'].to_s])
      converter_origin = converter_entry && converter_entry['originType'].to_s
      converter_statement_matches = converter_entry &&
                                    normalize_sql(converter_entry['statement']) == normalized
      origin, evidence =
        if override
          [override['origin_type'], "override: #{override['reason']}"]
        elsif converter_statement_matches && ALLOWED_ORIGINS.include?(converter_origin)
          [converter_origin, 'converter-emitted SQL provenance ledger']
        elsif source_sql.any? { |query| normalized == query }
          ['source-custom-sql', 'statement matches Tableau source Custom SQL']
        else
          ['unattributed', 'no exact source-SQL match, statement-bound converter ledger, or proven override']
        end
      {
        'element_id' => element['id'],
        'element_name' => element['name'],
        'origin_type' => origin,
        'status' => origin == 'unattributed' ? 'fail' : 'attributed',
        'evidence' => evidence,
        'statement_sha256' => Digest::SHA256.hexdigest(normalized)
      }
    end
    blockers = entries.select { |entry| entry['status'] == 'fail' }
    {
      'schema_version' => 1,
      'status' => blockers.empty? ? 'pass' : 'fail',
      'sql_elements' => entries,
      'blockers' => blockers,
      'dm_spec_sha256' => Digest::SHA256.hexdigest(spec_raw)
    }
  end

  def load_overrides(path)
    return {} unless path && File.file?(path)
    doc = JSON.parse(File.read(path))
    Array(doc.is_a?(Hash) ? doc['entries'] : doc).each_with_object({}) do |entry, out|
      next unless entry.is_a?(Hash)
      key = entry['element_id'].to_s
      key = entry['element_name'].to_s if key.empty?
      proof_path = entry['proof'].to_s
      proof_path = File.expand_path(proof_path, File.dirname(path)) unless proof_path.empty?
      proof = begin
        proof_path.empty? ? nil : JSON.parse(File.read(proof_path))
      rescue JSON::ParserError, SystemCallError
        nil
      end
      next if key.empty? || !ALLOWED_ORIGINS.include?(entry['origin_type'].to_s) ||
              entry['reason'].to_s.strip.empty? || !proof.is_a?(Hash) || proof['match'] != true
      out[key] = entry
    end
  end
end
