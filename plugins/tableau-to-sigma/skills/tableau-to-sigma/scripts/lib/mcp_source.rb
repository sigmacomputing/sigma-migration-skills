# frozen_string_literal: true

require 'json'
require 'csv'
require 'digest'
require 'fileutils'
require 'time'
require_relative 'twb_xml'

# A source-evidence boundary, not an MCP client. The driving agent uses its own
# authenticated Tableau MCP, then seals the returned files for deterministic reuse.
module McpSource
  class Incomplete < StandardError; end

  def self.prepare(workdir, twb: nil, workbook_id: nil, dashboards: [], seal: false)
    source = twb || File.join(workdir, 'workbook-content.twb')
    raise Incomplete, 'supply --twb <local workbook.twb>; Tableau PAT authentication is not needed' unless File.file?(source)
    raw = File.binread(source)
    utf16 = ["\xFF\xFE".b, "\xFE\xFF".b].include?(raw[0, 2])
    text = if utf16
             raw.encode('UTF-8', 'UTF-16')
           else
             raw.force_encoding('UTF-8').sub(/\A\uFEFF/, '')
           end
    snapshot = utf16 ? text.b : raw
    sha = Digest::SHA256.hexdigest(snapshot)
    canonical = File.join(workdir, 'workbook-content.twb')
    if File.file?(canonical)
      canonical_raw = File.binread(canonical)
      canonical_snapshot = if ["\xFF\xFE".b, "\xFE\xFF".b].include?(canonical_raw[0, 2])
                             canonical_raw.encode('UTF-8', 'UTF-16').b
                           else
                             canonical_raw
                           end
      canonical_sha = Digest::SHA256.hexdigest(canonical_snapshot)
    end
    if canonical_sha && canonical_sha != sha && File.expand_path(source) != File.expand_path(canonical)
      raise Incomplete, 'the supplied TWB differs from this workdir snapshot; use a new workdir for the new source revision (existing files were not deleted)'
    end
    File.binwrite(canonical, snapshot) unless canonical_raw == snapshot
    xml = TwbXml.parse(text)
    all_dashboards = xml.elements.to_a('/workbook/dashboards/dashboard')
    selected = if dashboards.empty?
                 all_dashboards
               else
                 dashboards.flat_map do |name|
                   exact = all_dashboards.select { |d| d.attributes['name'].to_s.casecmp?(name) }
                   hits = exact.empty? ? all_dashboards.select { |d| d.attributes['name'].to_s.downcase.include?(name.downcase) } : exact
                   if hits.empty?
                     hits = all_dashboards.select { |d| d.attributes['name'].to_s.gsub(/[^A-Za-z0-9]/, '').casecmp?(name.gsub(/[^A-Za-z0-9]/, '')) }
                   end
                   raise Incomplete, "dashboard scope #{name.inspect} must match exactly one source dashboard" unless hits.size == 1
                   hits
                 end.uniq
               end
    raise Incomplete, 'the local TWB has no dashboard in the requested scope' if selected.empty?
    worksheet_names = xml.elements.to_a('/workbook/worksheets/worksheet').map { |w| w.attributes['name'].to_s }
    required_sheets = selected.flat_map do |d|
      d.elements.to_a('zones//zone').map { |z| z.attributes['name'].to_s } & worksheet_names
    end.uniq
    required_dashboards = selected.map { |d| d.attributes['name'].to_s }
    metadata_path = File.join(workdir, 'get-workbook.json')
    metadata = File.file?(metadata_path) ? JSON.parse(File.read(metadata_path, encoding: 'bom|utf-8')) : {}
    raise Incomplete, 'get-workbook.json must contain a workbook object, not a tool wrapper or array' unless metadata.is_a?(Hash)
    workbook = metadata['workbook'] || metadata
    raise Incomplete, 'get-workbook.json workbook must be an object' unless workbook.is_a?(Hash)
    id = workbook['id']
    views = workbook.dig('views', 'view') || []
    views = [views] if views.is_a?(Hash)
    raise Incomplete, 'get-workbook.json views.view must be an array of view objects' unless views.is_a?(Array) && views.all? { |v| v.is_a?(Hash) }
    if id && workbook_id && id != workbook_id
      raise Incomplete, 'MCP workbook identity does not match --workbook-id; existing source files were preserved'
    end
    requests = []
    missing = []
    if !id.is_a?(String) || !id.match?(/\A[A-Za-z0-9_-]+\z/) || workbook['name'].to_s.empty?
      missing << 'get-workbook.json: save the Tableau MCP get-workbook result with workbook id, name, and views.view'
      requests << { 'tool' => 'get-workbook', 'workbook_id' => workbook_id, 'output' => 'get-workbook.json' }
    end
    files = ['workbook-content.twb', 'get-workbook.json']
    destinations = {}
    [[required_sheets, 'get-view-data'], [required_dashboards, 'get-view-image']].each do |names, tool|
      names.each do |name|
        matches = views.select { |v| v['name'] == name }
        view = matches.size == 1 ? matches.first : nil
        view_id = view && view['id'].to_s
        unless view_id && view_id.match?(/\A[A-Za-z0-9_-]+\z/)
          missing << "#{name}: resolve one exact view id with Tableau MCP (list-views if get-workbook omits worksheets)"
          requests << { 'tool' => tool, 'view_name' => name, 'view_id' => nil }
          next
        end
        filename = tool == 'get-view-data' ? "views/#{view_id}.csv" : "dashboards/#{name.gsub(/[^A-Za-z0-9._-]+/, '_')}.png"
        if destinations.key?(filename) && destinations[filename] != name
          raise Incomplete, "multiple source views map to #{filename}; resolve the ambiguous view identity before importing"
        end
        destinations[filename] = name
        files << filename
        requests << { 'tool' => tool, 'view_name' => name, 'view_id' => view_id, 'output' => filename, 'state' => 'saved-defaults' }
        path = File.join(workdir, filename)
        if !File.file?(path)
          missing << filename
        elsif tool == 'get-view-data'
          csv = CSV.read(path, headers: true, encoding: 'bom|utf-8')
          missing << "#{filename}: empty or non-tabular export" if csv.headers.nil? || csv.headers.empty?
        else
          header = File.binread(path, 24)
          missing << "#{filename}: not a PNG image" unless header.bytesize == 24 && header.start_with?("\x89PNG\r\n\x1a\n".b) && header[12, 4] == 'IHDR' && header[16, 8].unpack('NN').all?(&:positive?)
        end
      end
    end
    manifest_path = File.join(workdir, 'source-evidence.json')
    fingerprints = files.uniq.to_h do |name|
      path = File.join(workdir, name)
      [name, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
    end
    if seal && missing.empty?
      manifest = { 'schema_version' => 1, 'transport' => 'tableau-mcp', 'workbook_id' => id,
                   'workbook_updated_at' => workbook['updatedAt'], 'twb_sha256' => sha,
                   'captured_at' => Time.now.utc.iso8601, 'state' => 'saved-defaults',
                   'source_match_confirmed' => true, 'files' => fingerprints }
      File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
    end
    manifest = File.file?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}
    valid = manifest.is_a?(Hash) && manifest['transport'] == 'tableau-mcp' && manifest['workbook_id'] == id &&
            manifest['twb_sha256'] == sha && manifest['state'] == 'saved-defaults' &&
            manifest['source_match_confirmed'] == true &&
            manifest['files'].is_a?(Hash) && fingerprints.all? { |k, v| v && manifest['files'][k] == v }
    missing << 'source-evidence.json: seal the matching local TWB and saved-defaults MCP exports with import-tableau-mcp.rb' unless valid
    request = { 'schema_version' => 1, 'twb_sha256' => sha, 'dashboards' => required_dashboards,
                'worksheets' => required_sheets, 'requests' => requests, 'missing' => missing,
                'status' => missing.empty? ? 'ready' : 'needs-source-evidence' }
    File.write(File.join(workdir, 'mcp-evidence-request.json'), JSON.pretty_generate(request) + "\n")
    raise Incomplete, missing.join("\n  - ") unless missing.empty?
    workbook
  rescue JSON::ParserError, CSV::MalformedCSVError => e
    raise Incomplete, "source evidence is malformed (#{e.class}); replace that export, do not request a PAT"
  end
end
