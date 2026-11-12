# frozen_string_literal: true

require 'json'
require 'csv'
require 'digest'
require 'fileutils'
require 'time'
require 'zlib'
require_relative 'twb_xml'
require_relative 'zip_extract'

# A source-evidence boundary, not an MCP client. The driving agent uses its own
# authenticated Tableau MCP, then seals the returned files for deterministic reuse.
module McpSource
  class Incomplete < StandardError; end

  # Explicit local handoff, not invented Tableau REST view ids. Each hidden
  # worksheet CSV is attributed to a real parent dashboard get-view-data call.
  def self.worksheet_files(workdir, workbook, sealed: true)
    mapping = File.join(workdir, 'mcp-worksheet-files.json')
    return [] unless File.file?(mapping)
    entries = JSON.parse(File.read(mapping, encoding: 'UTF-8'))
    raise Incomplete, 'mcp-worksheet-files.json must be an array' unless entries.is_a?(Array)
    manifest = sealed ? JSON.parse(File.read(File.join(workdir, 'source-evidence.json'))) : nil
    if sealed && (manifest['workbook_id'] != workbook['id'] || manifest.dig('files', 'mcp-worksheet-files.json') != Digest::SHA256.file(mapping).hexdigest)
      raise Incomplete, 'worksheet file mapping is unsealed or belongs to another workbook'
    end
    parents = workbook.dig('views', 'view') || []
    parents = [parents] if parents.is_a?(Hash)
    parents = parents.select { |view| view.is_a?(Hash) }
    names = []
    entries.map do |entry|
      raise Incomplete, 'invalid worksheet file mapping' unless entry.is_a?(Hash) && entry['worksheet'].is_a?(String) && !entry['worksheet'].empty?
      raise Incomplete, 'duplicate worksheet file mapping; scope one dashboard at a time' if names.include?(entry['worksheet'])
      names << entry['worksheet']
      parent = parents.select { |view| view['id'] == entry['dashboard_view_id'] }
      raise Incomplete, 'worksheet export must name one real parent dashboard view id' unless parent.size == 1
      relative = entry['path'].to_s.tr('\\', '/')
      raise Incomplete, 'worksheet CSV path must be relative beneath views/' unless relative.start_with?('views/') && relative.end_with?('.csv') && !relative.split('/').include?('..')
      path = File.join(workdir, relative)
      raise Incomplete, 'worksheet CSV is missing or outside the workdir' unless File.file?(path) && File.realpath(path).start_with?(File.realpath(workdir) + File::SEPARATOR)
      if sealed && manifest.dig('files', relative) != Digest::SHA256.file(path).hexdigest
        raise Incomplete, 'worksheet CSV changed after source evidence was sealed'
      end
      { 'name' => entry['worksheet'], 'csv_path' => relative, 'dashboard_view_id' => entry['dashboard_view_id'],
        'dashboard_name' => parent.first['name'], 'source' => 'dashboard-worksheet-export' }
    end
  end

  def self.views_for(workdir, metadata)
    raise Incomplete, 'workbook metadata must be an object' unless metadata.is_a?(Hash)
    workbook = metadata['workbook'].is_a?(Hash) ? metadata.merge(metadata['workbook']) : metadata
    views = workbook.dig('views', 'view') || []
    views = [views] if views.is_a?(Hash)
    files = worksheet_files(workdir, workbook)
    views.reject { |view| files.any? { |file| file['name'] == view['name'] } } + files
  end

  def self.csv_path(workdir, view)
    return File.join(workdir, 'views', "#{view['id']}.csv") unless view['csv_path']
    relative = view['csv_path'].to_s.tr('\\', '/')
    raise Incomplete, 'invalid worksheet CSV path' unless relative.start_with?('views/') && relative.end_with?('.csv') && !relative.split('/').include?('..')
    File.join(workdir, relative)
  end

  def self.complete_png?(path)
    return false if File.size(path) > 128 * 1024 * 1024
    File.open(path, 'rb') do |file|
      return false unless file.read(8) == "\x89PNG\r\n\x1a\n".b
      header_seen = false
      data_seen = false
      loop do
        prefix = file.read(8)
        return false unless prefix && prefix.bytesize == 8
        length, type = prefix.unpack('Na4')
        return false if length > 32 * 1024 * 1024
        data, crc = file.read(length), file.read(4)
        return false unless data && data.bytesize == length && crc && crc.bytesize == 4
        return false unless Zlib.crc32(type + data) == crc.unpack1('N')
        unless header_seen
          return false unless type == 'IHDR' && length == 13 && data[0, 8].unpack('NN').all?(&:positive?)
          header_seen = true
          next
        end
        data_seen = true if type == 'IDAT'
        return data_seen && length.zero? && file.eof? if type == 'IEND'
      end
    end
  rescue SystemCallError
    false
  end

  def self.prepare(workdir, twb: nil, workbook_id: nil, dashboards: [], seal: false)
    source = twb || File.join(workdir, 'workbook-content.twb')
    raise Incomplete, 'supply --twb <local workbook.twb>; Tableau PAT authentication is not needed' unless File.file?(source)
    raise Incomplete, 'source package exceeds the 512 MiB local ingestion limit; supply its standalone TWB instead' if File.size(source) > 512 * 1024 * 1024
    raw = File.binread(source)
    if raw.start_with?("PK\x03\x04".b)
      members = ZipExtract.entries(source).select { |name| name.downcase.end_with?('.twb') }
      raise Incomplete, 'TWBX must contain exactly one TWB; select a standalone TWB when the package is ambiguous' unless members.size == 1
      raw = ZipExtract.read(source, members.first, max_bytes: 32 * 1024 * 1024)
    end
    raise Incomplete, 'TWB exceeds the 32 MiB XML ingestion limit' if raw.bytesize > 32 * 1024 * 1024
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
    File.binwrite(canonical, snapshot) unless canonical_raw == snapshot
    metadata_path = File.join(workdir, 'get-workbook.json')
    metadata = File.file?(metadata_path) ? JSON.parse(File.read(metadata_path, encoding: 'bom|utf-8')) : {}
    raise Incomplete, 'get-workbook.json must contain a workbook object, not a tool wrapper or array' unless metadata.is_a?(Hash)
    workbook = metadata['workbook'] || metadata
    raise Incomplete, 'get-workbook.json workbook must be an object' unless workbook.is_a?(Hash)
    workbook = metadata.merge(workbook)
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
    embedded = worksheet_files(workdir, workbook, sealed: false)
    files << 'mcp-worksheet-files.json' if File.file?(File.join(workdir, 'mcp-worksheet-files.json'))
    embedded.each do |entry|
      parent = all_dashboards.find { |dashboard| dashboard.attributes['name'] == entry['dashboard_name'] }
      names = parent && parent.elements.to_a('zones//zone').map { |zone| zone.attributes['name'] }
      raise Incomplete, 'worksheet mapping does not match its source dashboard' unless names && names.include?(entry['name'])
      if required_sheets.include?(entry['name'])
        owners = selected.select { |dashboard| dashboard.elements.to_a('zones//zone').any? { |zone| zone.attributes['name'] == entry['name'] } }
        unless owners.size == 1 && owners.first.attributes['name'] == entry['dashboard_name']
          raise Incomplete, 'embedded worksheet defaults are dashboard-specific; scope one matching dashboard per workdir'
        end
      end
    end
    files.concat(embedded.map { |entry| entry['csv_path'] })
    destinations = {}
    [[required_sheets, 'get-view-data'], [required_dashboards, 'get-view-image']].each do |names, tool|
      names.each do |name|
        matches = views.select { |v| v['name'] == name }
        view = matches.size == 1 ? matches.first : nil
        file_view = tool == 'get-view-data' && embedded.find { |entry| entry['name'] == name }
        if file_view
          files << file_view['csv_path']
          csv = CSV.read(File.join(workdir, file_view['csv_path']), headers: true, encoding: 'bom|utf-8')
          missing << "#{file_view['csv_path']}: empty or non-tabular export" if csv.headers.nil? || csv.headers.empty?
          requests << { 'tool' => tool, 'view_id' => file_view['dashboard_view_id'], 'worksheet' => name,
                        'output' => file_view['csv_path'], 'state' => 'saved-defaults' }
          next
        end
        view_id = view && view['id'].to_s
        unless view_id && view_id.match?(/\A[A-Za-z0-9_-]+\z/)
          if tool == 'get-view-data'
            owners = selected.select { |dashboard| dashboard.elements.to_a('zones//zone').any? { |zone| zone.attributes['name'] == name } }
            parent_views = owners.size == 1 ? views.select { |candidate| candidate['name'] == owners.first.attributes['name'] } : []
            if parent_views.size == 1 && parent_views.first['id'].to_s.match?(/\A[A-Za-z0-9_-]+\z/)
              filename = "views/worksheet-#{Digest::SHA256.hexdigest(name)[0, 16]}.csv"
              missing << "#{name}: capture the worksheet from its parent dashboard export and record it in mcp-worksheet-files.json; do not invent a REST view id"
              requests << { 'tool' => tool, 'view_id' => parent_views.first['id'], 'worksheet' => name,
                            'output' => filename, 'mapping_file' => 'mcp-worksheet-files.json', 'state' => 'saved-defaults' }
              next
            end
          end
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
          missing << "#{filename}: not a PNG image, or incomplete/corrupt PNG; save the full image to a file rather than a truncated tool response" unless complete_png?(path)
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
  rescue StandardError => e
    raise if e.is_a?(Incomplete)
    raise Incomplete, "local source could not be prepared (#{e.class}); no Tableau authentication fallback was attempted"
  end
end
