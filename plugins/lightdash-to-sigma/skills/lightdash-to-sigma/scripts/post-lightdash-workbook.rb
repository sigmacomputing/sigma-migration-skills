#!/usr/bin/env ruby
# frozen_string_literal: true
# POST the workbook built by build-lightdash-workbook.rb (POST /v2/workbooks/spec via
# Sigma::CodeRep), then read it back to wb-readback.json (the evidence assert-phase6-ran.rb reads).
# --dry-run prints the planned calls and performs NONE (no token needed). A real run first POSTs the same body with
# dryRun:true (server-side validation, creates nothing) and stops with the readable errors if it is invalid.
#
#   ruby scripts/post-lightdash-workbook.rb --spec wb.json --out wb-ids.json [--dry-run]
#
# --spec accepts the builder envelope ({workbook: {...}}) or a bare workbook spec. Also writes
# wb-spec.json (the authored document) next to --out.

require 'optparse'
require 'json'
require_relative 'lib/ruby_compat'
require_relative 'lib/code_rep'

module PostLightdashWorkbook
  module_function

  def unwrap(raw)
    raw.is_a?(Hash) && raw['workbook'].is_a?(Hash) ? raw['workbook'] : raw
  end

  # Dry-run validation POST (`dryRun: true`; nothing is created). Returns the normalized
  # { 'valid' => bool, 'errors' => [{ 'summary' => ... }], 'warnings' => [...] } so a schema problem is shown
  # readably BEFORE the real POST instead of surfacing as a raw HTTP error body.
  def validate(spec)
    require_relative 'lib/sigma_rest'
    r = Sigma.request(:post, Sigma::CodeRep.create_path, body: Sigma::CodeRep.create_body(spec, dry_run: true).to_json)
    Sigma::CodeRep.dry_run_result(200, r)
  rescue Sigma::Error => e
    head, tail = e.message.split("\n", 2)
    status = head.to_s[/-> (\d{3})/, 1].to_i
    body = begin
      JSON.parse(tail.to_s)
    rescue JSON::ParserError
      {}
    end
    res = Sigma::CodeRep.dry_run_result(status, body)
    res['errors'] = [{ 'summary' => head.to_s }] if status.zero?
    res
  end

  def planned_calls(spec)
    body = Sigma::CodeRep.create_body(spec)
    els = Sigma::CodeRep.workbook_elements(Sigma::CodeRep.document(spec)).length
    [{ 'method' => 'POST', 'path' => Sigma::CodeRep.create_path, 'name' => spec['name'],
       'elements' => els, 'body_bytes' => JSON.generate(body).bytesize },
     { 'method' => 'GET', 'path' => Sigma::CodeRep.read_path('<workbookId>'), 'purpose' => 'readback -> wb-readback.json' }]
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--spec PATH') { |v| opts[:spec] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--dry-run') { opts[:dry_run] = true }
  end.parse!(ARGV)
  { spec: '--spec', out: '--out' }.each { |k, f| abort "missing #{f}" if opts[k].to_s.empty? }
  spec = PostLightdashWorkbook.unwrap(JSON.parse(File.read(opts[:spec], encoding: 'UTF-8')))
  dir = File.dirname(File.expand_path(opts[:out]))
  File.write(File.join(dir, 'wb-spec.json'), JSON.pretty_generate(spec) + "\n")
  if opts[:dry_run]
    PostLightdashWorkbook.planned_calls(spec).each { |c| warn "DRY-RUN (not performed): #{c.to_json}" }
    exit 0
  end
  require_relative 'lib/sigma_rest'
  check = PostLightdashWorkbook.validate(spec)
  check['warnings'].each { |w| warn "dry-run warning: #{w.is_a?(Hash) ? (w['summary'] || w.to_json) : w}" }
  unless check['valid']
    warn 'workbook spec failed the dry-run validation (nothing was created):'
    check['errors'].each { |er| warn "  - #{er.is_a?(Hash) ? (er['summary'] || er['message'] || er.to_json) : er}" }
    exit 1
  end
  posted =Sigma.request(:post, Sigma::CodeRep.create_path, body: Sigma::CodeRep.create_body(spec).to_json)
  id = posted['workbookId'] or abort "POST #{Sigma::CodeRep.create_path} returned no workbookId: #{posted.inspect[0, 200]}"
  File.write(opts[:out], JSON.pretty_generate('workbookId' => id) + "\n")
  readback = Sigma.request(:get, Sigma::CodeRep.read_path(id))
  File.write(File.join(dir, 'wb-readback.json'), JSON.pretty_generate(readback) + "\n")
  warn "posted workbook #{id}; readback written to wb-readback.json"
end
