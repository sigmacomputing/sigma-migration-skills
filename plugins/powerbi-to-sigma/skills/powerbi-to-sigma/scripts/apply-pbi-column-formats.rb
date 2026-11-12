#!/usr/bin/env ruby
# frozen_string_literal: true
# apply-pbi-column-formats.rb — post-build pass for an already-built workbook spec: add the
# Power BI static per-column fills (matrix/table `columnFormatting` backColor/fontColor,
# captured by extract-pbir as visual `column_formats`) as Sigma conditionalFormats, and rewrite
# settings.theme.overrides.categoricalScheme + colors.highlight to the report theme's palette
# (signals `theme_data_colors`, else the built-in table). Idempotent.
#
#   ruby scripts/apply-pbi-column-formats.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--theme-only]
#
# Header-only / total-only fills cannot be reproduced (Sigma has no per-column header or
# grand-total fill) and are listed in the summary. See refs/style-fidelity.md.
require 'json'
require 'optparse'
require_relative 'lib/ruby_compat'
require_relative 'lib/pbi_column_format_apply'

opts = {}
usage = 'usage: apply-pbi-column-formats.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--theme-only]'
OptionParser.new do |p|
  p.banner = usage
  p.on('--spec PATH', 'workbook spec JSON (input)') { |v| opts[:spec] = v }
  p.on('--signals PATH', 'signals.json from extract-pbir.py') { |v| opts[:signals] = v }
  p.on('--out PATH', 'output spec (default: rewrite --spec in place)') { |v| opts[:out] = v }
  p.on('--theme-only', 'only rewrite the theme palette; add no column fills') { opts[:theme_only] = true }
end.parse!
abort(usage) unless opts[:spec] && opts[:signals]

spec = JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))
signals = JSON.parse(File.read(opts[:signals], encoding: 'UTF-8'))
sum = PbiColumnFormatApply.apply(spec, signals, theme_only: opts[:theme_only] ? true : false)

dest = opts[:out] || opts[:spec]
File.binwrite(dest, JSON.pretty_generate(spec))

warn "[apply-pbi-column-formats] palette (#{sum['palette'].length}): #{sum['palette'].join(' ')}" \
     "#{sum['theme_changed'] ? ' (theme rewritten)' : ' (theme already current)'}" \
     "; #{sum['kpis_recolored']} KPI value color(s) set to the theme card color"
sum['elements'].each do |e|
  warn "[apply-pbi-column-formats] #{e['name']} (#{e['id']}): +#{e['added']} rule(s), -#{e['removed'].to_i} stale, " \
       "#{e['skipped_existing']} already present"
  e['coverage'].each { |c| warn "[apply-pbi-column-formats]   skipped (#{c[:severity]}): #{c[:detail]}" }
end
total = sum['elements'].inject(0) { |a, e| a + e['added'] }
warn "[apply-pbi-column-formats] #{total} rule(s) added across #{sum['elements'].length} element(s) -> #{dest}"
