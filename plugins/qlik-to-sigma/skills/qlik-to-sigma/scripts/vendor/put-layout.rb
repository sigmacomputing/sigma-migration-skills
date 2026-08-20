#!/usr/bin/env ruby
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <Container> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit Containers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML; this script injects those elements (containers + header
# text) into the document-global `elements` collection before the PUT. Pages
# are metadata-only; page membership comes from layout XML. Pass --elements
# to override the sidecar path. Injection is idempotent by element id.
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>]

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
TOK  = ENV.fetch('SIGMA_API_TOKEN')

def http(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :get then Net::HTTP::Get.new(uri)
        when :put then r = Net::HTTP::Put.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json'
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

xml = File.read(opts[:layout])
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

raw_spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec").body)
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08) and REJECTS the old flat body on PUT
# with a 400 — unwrap the GET before any spec['pages'] access below; this
# endpoint is workbook-only (data-model code-rep is confirmed unchanged).
spec = Sigma::CodeRep.document(raw_spec)
spec['layout'] = xml

# Inject container/header-text spec elements (see header comment).
elements_path = opts[:elements] || "#{opts[:layout]}.elements.json"
if File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  spec['elements'] ||= []
  existing = spec['elements'].filter_map { |e| e['id'] if e.is_a?(Hash) }
  inject.each do |page_id, els|
    unless Array(spec['pages']).any? { |p| p['id'] == page_id }
      warn "WARN: elements sidecar references unknown page #{page_id.inspect} — skipped"
      next
    end
    els.each do |el|
      next if existing.include?(el['id'])
      spec['elements'] << el
      existing << el['id']
      injected += 1
    end
  end
  puts "injected #{injected} container/header element(s) from #{elements_path}"
end
# Preserve the complete document from GET (flat elements, overlays, panels,
# settings, agents, and future document fields known to CodeRep); mutate only
# layout plus optional injected elements. UpdateWorkbookSpec accepts only the
# document envelope, so response metadata correctly stays out of the PUT.
resp = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", JSON.pretty_generate(Sigma::CodeRep.wrap(spec)))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
