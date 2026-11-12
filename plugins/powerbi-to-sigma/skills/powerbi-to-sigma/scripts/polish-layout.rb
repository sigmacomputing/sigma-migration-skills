#!/usr/bin/env ruby
# frozen_string_literal: true
# polish-layout.rb — layout POLISH pass: keep the source's ARRANGEMENT (grouping + reading order) but
# render it to the house design rules. Runs AFTER any layout mode (`--layout pbi|clean|banded`).
#
#   ruby scripts/polish-layout.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--layout-out L.xml]
#
# Rewrites the spec's layout (top-level `layout` or `document.layout`, whichever it came in as), adds /
# removes the `kind: container` placeholder elements, and applies the element tweaks (presentation
# tables, blank nulls, heading marks). Without --out the spec is rewritten IN PLACE. Prints a per-page
# summary to stderr. Deterministic and idempotent. The rules are documented in lib/polish_layout.rb and
# refs/large-pbix.md ("Polish the layout").
require 'json'
require 'optparse'
require_relative 'lib/ruby_compat'
require_relative 'lib/polish_layout'

opts = {}
OptionParser.new do |p|
  p.banner = 'usage: polish-layout.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--layout-out L.xml] [--hide-derived-titles]'
  p.on('--spec PATH', 'workbook spec JSON (input)') { |v| opts[:spec] = v }
  p.on('--signals PATH', 'signals.json (source visual boxes, absolute canvas px)') { |v| opts[:signals] = v }
  p.on('--out PATH', 'output spec (default: rewrite --spec in place)') { |v| opts[:out] = v }
  p.on('--layout-out PATH', 'also write the new layout XML here') { |v| opts[:layout_out] = v }
  p.on('--hidden-controls MODE', 'drawer (default: a Filters drawer + open button) or band (bottom band)') { |v| opts[:hidden] = v }
  p.on('--hide-derived-titles', 'hide (name " ") the builder-derived name of a table/pivot whose source shows no title. Opt-in: preflight N1 rejects a whitespace name until the shared lint exempts tables/pivots') { opts[:hide_titles] = true }
end.parse!
abort('usage: polish-layout.rb --spec WB.json --signals SIGNALS.json [--out OUT.json] [--layout-out L.xml] [--hide-derived-titles]') \
  unless opts[:spec] && opts[:signals]

spec = JSON.parse(File.read(opts[:spec], encoding: 'UTF-8'))
signals = JSON.parse(File.read(opts[:signals], encoding: 'UTF-8'))

begin
  out, summaries = PolishLayout.polish(spec, signals, hidden_controls: opts[:hidden] || 'drawer',
                                         hide_derived_titles: opts[:hide_titles] ? true : false)
rescue ArgumentError => e
  abort("[polish-layout] #{e.message}")
end

dest = opts[:out] || opts[:spec]
File.binwrite(dest, JSON.pretty_generate(out))
File.binwrite(opts[:layout_out], PolishLayout.doc_of(out)['layout']) if opts[:layout_out]

summaries.each do |s|
  warn format('[polish-layout] page %s (%s): header %s; controls %d visible / %d hidden; legends %d kept / %d dropped; ' \
              '%d content element(s); %d rows; arrangement: %s',
              s['page_id'], s['page_title'].inspect, s['header'], s['controls_visible'], s['controls_hidden'],
              s['legends_kept'], s['legends_dropped'], s['content'], s['rows'], s['shape'])
  s['notes'].each { |n| warn "[polish-layout]   note: #{n}" }
end
warn "[polish-layout] #{summaries.length} page(s) polished -> #{dest}" \
     "#{summaries.empty? ? ' (no spec page matched a signals page: nothing changed)' : ''}"
