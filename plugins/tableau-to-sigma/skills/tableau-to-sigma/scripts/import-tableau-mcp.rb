#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/mcp_source'
require_relative 'lib/workdir_guard'
require_relative 'lib/migration_process'

opts = { dashboards: [] }
OptionParser.new do |p|
  p.banner = 'Usage: import-tableau-mcp.rb --twb FILE --workdir DIR --workbook-id ID --confirm-source-match'
  p.on('--twb PATH') { |v| opts[:twb] = File.expand_path(v) }
  p.on('--workdir DIR') { |v| opts[:workdir] = WorkdirGuard.check!(File.expand_path(v), '--workdir') }
  p.on('--workbook-id ID') { |v| opts[:workbook_id] = v }
  p.on('--dashboard NAME') { |v| opts[:dashboards] << v }
  p.on('--confirm-source-match', 'Confirm the TWB matches the MCP workbook revision and all exports use its saved defaults') { opts[:confirm] = true }
end.parse!
abort 'required: --twb, --workdir, --workbook-id, --confirm-source-match (never infer source identity)' unless
  opts.values_at(:twb, :workdir, :workbook_id, :confirm).all?
FileUtils.mkdir_p(opts[:workdir])
begin
  MigrationProcess.acquire(opts[:workdir])
  McpSource.prepare(opts[:workdir], twb: opts[:twb], workbook_id: opts[:workbook_id], dashboards: opts[:dashboards], seal: true)
  puts 'MCP source evidence sealed; resume migrate-tableau.rb --twb with the same workdir. No Tableau REST calls made.'
rescue MigrationProcess::Busy => e
  warn e.message
  exit 28
rescue McpSource::Incomplete => e
  warn "MCP SOURCE STOP:\n  - #{e.message}\nSee mcp-evidence-request.json. Existing files were preserved."
  exit 30
end
