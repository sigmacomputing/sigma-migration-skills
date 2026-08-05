#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-visual-source-fallback.rb — #422: verify-dashboard-visual.rb must stage
# the SOURCE dashboard PNG from the discovery-saved dashboards/<name>.png when
# the live Tableau fetch env is incomplete (a re-entry shell often lacks
# TABLEAU_SITE_ID / TABLEAU_AUTH_TOKEN) instead of leaving the pair INCOMPLETE
# with "TABLEAU_SITE_ID not set" — discovery already saved the image on disk.
#
# Offline, creds-free (the Sigma render side is skipped: no matching page).
# Run: ruby scripts/test-visual-source-fallback.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'verify-dashboard-visual.rb')
RUBY   = RbConfig.ruby
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# Env WITHOUT any Tableau credentials — the re-entry shell shape.
NO_TABLEAU_ENV = { 'TABLEAU_SITE_ID' => nil, 'TABLEAU_AUTH_TOKEN' => nil,
                   'TABLEAU_SERVER_URL' => nil, 'TABLEAU_PAT_NAME' => nil,
                   'TABLEAU_PAT_SECRET' => nil, 'TABLEAU_SITE_CONTENT_URL' => nil }.freeze

def stage(dir, with_view:)
  name = 'Exec Overview'
  File.write(File.join(dir, 'dashboard-layout.json'),
             JSON.generate([{ 'dashboard' => name, 'zones' => [] }]))
  # Only a Data page → the Sigma render side is skipped (no page to render);
  # this isolates the SOURCE staging path.
  File.write(File.join(dir, 'wb-ids.json'),
             JSON.generate('pages' => [{ 'id' => 'pg-d', 'name' => 'Data', 'elements' => [] }]))
  if with_view
    # get-workbook.json resolves a view id, so the script ATTEMPTS the live
    # fetch — which raises the exact "TABLEAU_* not set" the live run hit.
    File.write(File.join(dir, 'get-workbook.json'),
               JSON.generate('views' => { 'view' => [{ 'name' => name, 'id' => 'v-1' }] }))
  end
  FileUtils.mkdir_p(File.join(dir, 'dashboards'))
  # tableau-discover.rb 3b filename convention: non-word runs → underscore.
  File.binwrite(File.join(dir, 'dashboards', 'Exec_Overview.png'), "\x89PNG-fake-bytes")
  out, st = Open3.capture2e(NO_TABLEAU_ENV, RUBY, SCRIPT, '--workbook', 'WBID', '--tableau-dir', dir)
  [out, st, File.join(dir, 'visual-qa', 'exec-overview.source.png')]
end

puts '-- discovery-PNG fallback, no view id resolvable (no get-workbook.json)'
Dir.mktmpdir do |d|
  out, _st, src = stage(d, with_view: false)
  ok('source PNG staged from the discovery-saved dashboards/*.png', File.size?(src))
  ok('fallback NOTE printed', out.include?('discovery-saved'))
  man = JSON.parse(File.read(File.join(d, 'visual-qa', 'compare-manifest.json')))
  ok('compare-manifest records the staged source_png', man[0]['source_png'] == src)
end

puts '-- discovery-PNG fallback after the live fetch fails (TABLEAU_* env missing)'
Dir.mktmpdir do |d|
  out, _st, src = stage(d, with_view: true)
  ok('live fetch failed on the missing Tableau env (the #422 failure)',
     out =~ /TABLEAU_\w+ not set/)
  ok('…but the source PNG is STILL staged from dashboards/*.png', File.size?(src))
  man = JSON.parse(File.read(File.join(d, 'visual-qa', 'compare-manifest.json')))
  ok('compare-manifest records the staged source_png', man[0]['source_png'] == src)
end

puts($fail.zero? ? "\nALL PASS — visual source-PNG fallback" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
