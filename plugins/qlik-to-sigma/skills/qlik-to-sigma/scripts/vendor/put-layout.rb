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
require 'sigma_rest'
require 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative '../lib/ruby_compat'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

# Host and token come from the shared client: SIGMA_BASE_URL / SIGMA_API_TOKEN
# when exported, else a signed-in Sigma CLI profile (or browser login / client
# credentials) through the token provider.
def sigma_base
  @sigma_base ||= Sigma.base_url
rescue Sigma::Error => e
  abort "put-layout: #{e.message}"
end

def http(method, path, body = nil)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{sigma_base}#{path}")
    req = case method
          when :get then Net::HTTP::Get.new(uri)
          when :put then r = Net::HTTP::Put.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
          end
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept']        = 'application/json'
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1
      warn '  [auth] Sigma token expired mid-run, refreshing and retrying...'
      refreshed = begin
        Sigma.refresh_token!
        true
      rescue StandardError => e
        warn "  [auth] token refresh failed: #{e.message.lines.first.to_s.strip}"
        false
      end
      next if refreshed
    end
    return res
  end
end

# encoding: 'UTF-8' is NOT optional — this layout XML is regexp-matched below and
# carries element titles straight from the source dashboard, so em-dashes and
# curly quotes are the norm. A raw read inherits the locale's default external
# encoding and raises `invalid byte sequence in US-ASCII`. F5 crash class, #752.
xml = File.read(opts[:layout], encoding: 'UTF-8')
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

raw_spec = JSON.parse(http(:get, Sigma::CodeRep.read_path(opts[:wb])).body)
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `contents` key and REJECTS the old flat body on PUT with a 400 — unwrap the GET before any spec['pages'] access below; this
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
# layout plus optional injected elements. The contents PUT accepts only the
# contents envelope, so response metadata correctly stays out of the PUT.
resp = http(:put, Sigma::CodeRep.update_path(opts[:wb]), JSON.pretty_generate(Sigma::CodeRep.update_body(spec)))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
