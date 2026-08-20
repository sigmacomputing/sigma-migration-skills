#!/usr/bin/env ruby
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <Container> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit Containers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML. Workbook elements are now a flat document collection, so
# this script injects every sidecar element into document.elements; page
# membership comes only from the authoritative layout. Injection is
# idempotent (existing element ids are kept).
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>]

require 'json'
require 'yaml'
require 'date'
require 'optparse'
# sigma_rest self-exchanges SIGMA_CLIENT_ID/SECRET (auto-loading
# ~/.sigma-migration/env) exactly like the phase 1-4 scripts — SIGMA_API_TOKEN
# is optional, not a hard requirement (bead eqom).
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'code_rep'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

def http(method, path, body = nil)
  Sigma.request(method, path, body: body, binary: true)
end

xml = File.read(opts[:layout])
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

raw_spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec"))
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08) and REJECTS the old flat body on PUT
# with a 400 — unwrap the GET before any spec['pages'] access below; this
# endpoint is workbook-only (data-model code-rep is confirmed unchanged).
spec = Sigma::CodeRep.document(raw_spec)
spec['pages'].each { |p| p.delete('layout') }
spec['layout'] = xml

# Inject container/header-text spec elements (see header comment).
elements_path = opts[:elements] || "#{opts[:layout]}.elements.json"
if File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  spec['elements'] ||= []
  existing = Sigma::CodeRep.workbook_elements(spec).map { |e| e['id'] }
  page_ids = Array(spec['pages']).filter_map { |page| page['id'] }
  inject.each do |page_id, els|
    unless page_ids.include?(page_id)
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
# Read-only metadata (workbookId, url, ownerId, createdBy, updatedBy,
# createdAt, updatedAt, latestDocumentVersion) never reaches `spec` in the
# first place now — Sigma::CodeRep.document() above already unwraps to just
# the document fields (schemaVersion/pages/kind/layout), so there is nothing
# left here to strip before the PUT.

begin
  resp_body = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", JSON.pretty_generate(Sigma::CodeRep.wrap(spec)))
rescue Sigma::Error => e
  puts "ERROR: #{e.message}"
  exit 1
end
parsed = YAML.safe_load(resp_body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
