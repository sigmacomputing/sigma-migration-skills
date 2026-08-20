#!/usr/bin/env ruby
# test-put-layout.rb — put-layout.rb must REPAIR `navigate` button targets at
# publish time (Task 5). Two page-id schemes coexist in this codebase —
# build-workbook-spec.rb:177 "page-<slug>" vs mechanical-specs.rb:1881
# "page-dash-<N>" (array index, the orchestrated pipeline customers run) — so
# build-charts-from-signals.rb cannot know the final page id when it emits a
# `navigate` action. It emits a PROVISIONAL target.page and records the
# human-readable dashboard/page NAME on the <out>-actions-emitted.json
# manifest (`targetPageName`, keyed by `actionId`). put-layout.rb must, after
# publish, resolve that name against the live spec's pages and rewrite
# target.page — through the SAME page_id_by_name lookup the existing
# nav.invalid URL rewrite uses (not a second one).
#
# AMENDMENT NOTE: an earlier version of this plan told put-layout.rb to SKIP
# buttons carrying a `navigate` effect, on the (false) assumption their page
# ids were already correct at build time. That is wrong and is NOT what this
# test (or the implementation it pins) does — buttons with `navigate` are
# never skipped; their target is repaired.
#
# Loopback WEBrick over http:// (same harness as test-put-layout-prune.rb) —
# offline, creds-free. Run: ruby scripts/test-put-layout.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SCRIPT = File.expand_path('put-layout.rb', __dir__)

def run_case(live_spec, layout_xml, manifest_entries)
  Dir.mktmpdir do |work|
    put_bodies = []
    srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                  Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    port = srv.config[:Port]
    srv.mount_proc('/') do |req, res|
      if req.request_method == 'GET' && req.path.end_with?('/spec')
        res.body = JSON.generate(live_spec)
      elsif req.request_method == 'GET'
        # workbook metadata GET (used by the nav.invalid URL rewrite, unrelated
        # to this test, but put-layout.rb always issues it once nav-buttons.json
        # exists) — a URL keeps that code path harmless here.
        res.body = JSON.generate('url' => "http://127.0.0.1:#{port}/wb")
      else # PUT
        put_bodies << req.body
        res.body = { 'workbookId' => 'wb-test' }.to_json
      end
      res['Content-Type'] = 'application/json'
      res.status = 200
    end
    th = Thread.new { srv.start }

    File.write(File.join(work, 'auth.json'),
               { 'SIGMA_API_TOKEN' => 'filetok', 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}" }.to_json)
    layout = File.join(work, 'layout.xml')
    File.write(layout, layout_xml, encoding: 'UTF-8')
    manifest_path = layout.sub(/\.xml$/, '') + '-actions-emitted.json'
    File.write(manifest_path, JSON.generate(manifest_entries))

    scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil,
              'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil, 'HOME' => work }
    out, st = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)

    put_bodies_parsed = put_bodies.map do |b|
      raw = JSON.parse(b) rescue {}
      raw['document'].is_a?(Hash) ? raw['document'] : raw
    end
    [st, out, put_bodies_parsed]
  end
end

def elements_from_spec(spec)
  spec['elements'] || spec.fetch('pages', []).flat_map { |page| page['elements'] || [] }
end

# ---------------------------------------------------------------------------
puts 'Case 1 - navigate target repaired by name to the DIFFERENT live page id'
# The button was emitted with a PROVISIONAL target 'page-wrong-slug' (as
# build-charts-from-signals.rb would under the page-<slug> scheme), but the
# orchestrated pipeline actually assigned this page 'page-dash-2' by array
# index — the exact page-id-scheme mismatch the amendment describes.
LAYOUT_XML_1 = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-dash-1">
  <Element elementId="btn-10" gridColumn="1 / 25" gridRow="1 / 3"/>
  </Page>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-dash-2">
  </Page>
XML
MANIFEST_1 = [
  { 'actionId' => 'act-btn-10-1', 'hostElementId' => 'btn-10', 'trigger' => 'on-click',
    'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'page-wrong-slug' } }],
    'targetPageName' => 'Detail View',
    'source' => { 'kind' => 'nav-button', 'caption' => 'Details' } }
].freeze
LIVE_SPEC_1_WITH_BUTTON = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => [
      { 'id' => 'page-dash-1', 'name' => 'Overview' },
      { 'id' => 'page-dash-2', 'name' => 'Detail View' }
    ],
    'elements' => [
      { 'id' => 'btn-10', 'kind' => 'button', 'text' => 'Details',
        'actions' => [{ 'id' => 'act-btn-10-1', 'trigger' => 'on-click',
                        'effects' => [{ 'effect' => 'navigate',
                                        'target' => { 'type' => 'page', 'page' => 'page-wrong-slug' } }] }] }
    ],
    'layout' => LAYOUT_XML_1
  }
}.freeze

st1, out1, puts1 = run_case(LIVE_SPEC_1_WITH_BUTTON, LAYOUT_XML_1, MANIFEST_1)
check(st1.exitstatus == 0, 'exits 0')
check(puts1.length == 1, 'exactly one PUT sent')
btn1 = elements_from_spec(puts1.first || {}).find { |e| e['id'] == 'btn-10' }
eff1 = btn1 && (btn1['actions'] || []).first&.dig('effects', 0)
# Assert on the REPAIRED spec that came back over the wire, not on a locally
# constructed expectation.
check(!eff1.nil? && eff1['target']['page'] == 'page-dash-2',
      'navigate target.page repaired to page-dash-2 (the id of the page named "Detail View")')
check(!eff1.nil? && eff1['target']['page'] != 'page-wrong-slug',
      'target.page is no longer the provisional page-wrong-slug')
check(out1.include?('navigate targets: 1 button action(s) repaired'), 'repair reported on stdout')
puts out1 unless st1.exitstatus == 0

puts
puts 'Case 2 - unresolvable targetPageName: warn loudly, do not crash, leave provisional value in place'
MANIFEST_2 = [
  { 'actionId' => 'act-btn-10-1', 'hostElementId' => 'btn-10', 'trigger' => 'on-click',
    'effects' => [{ 'effect' => 'navigate', 'target' => { 'type' => 'page', 'page' => 'page-wrong-slug' } }],
    'targetPageName' => 'Nonexistent Page',
    'source' => { 'kind' => 'nav-button', 'caption' => 'Details' } }
].freeze

st2, out2, puts2 = run_case(LIVE_SPEC_1_WITH_BUTTON, LAYOUT_XML_1, MANIFEST_2)
check(st2.exitstatus == 0, 'exits 0 (unresolved target is a warning, not a crash)')
btn2 = elements_from_spec(puts2.first || {}).find { |e| e['id'] == 'btn-10' }
eff2 = btn2 && (btn2['actions'] || []).first&.dig('effects', 0)
check(!eff2.nil? && eff2['target']['page'] == 'page-wrong-slug',
      'provisional target.page left in place (page-wrong-slug) when the name does not resolve')
check(out2.include?('WARN') && out2.include?('act-btn-10-1') && out2.include?('Nonexistent Page'),
      'a clear WARN names both the action and the unresolved page name')
check(!out2.include?('navigate targets: 1 button'), 'no repair claimed on stdout for the unresolved case')
puts out2 unless st2.exitstatus == 0

puts
puts 'Case 3 - --apply-pivot-totals with no --layout accepts a valid empty workbook'
# The released workbook-code contract requires pages, elements, and layout.
# Exercise the totals-only ship pass with their valid empty values; malformed
# readbacks are now intentionally rejected by put-layout's pre-PUT validator.
Dir.mktmpdir do |work|
  put_bodies = []
  srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
  port = srv.config[:Port]
  srv.mount_proc('/') do |req, res|
    if req.request_method == 'GET' && req.path.end_with?('/spec')
      res.body = JSON.generate(
        'document' => {
          'schemaVersion' => 1, 'kind' => 'workbook',
          'pages' => [], 'elements' => [], 'layout' => '<Workbook/>'
        }
      )
    elsif req.request_method == 'GET'
      res.body = JSON.generate('url' => "http://127.0.0.1:#{port}/wb")
    else # PUT
      put_bodies << req.body
      res.body = { 'workbookId' => 'wb-test' }.to_json
    end
    res['Content-Type'] = 'application/json'
    res.status = 200
  end
  th = Thread.new { srv.start }

  File.write(File.join(work, 'auth.json'),
             { 'SIGMA_API_TOKEN' => 'filetok', 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}" }.to_json)

  scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil,
            'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil, 'HOME' => work }
  out3, st3 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work),
                              'ruby', SCRIPT, '--workbook', 'wb-test',
                              '--apply-pivot-totals', '--workdir', work)

  check(st3.exitstatus == 0, "exits 0 (no --layout, valid empty workbook) — got #{st3.exitstatus}")
  check(put_bodies.length == 1, 'PUT still sent (the totals pass ran to completion, not just avoided crashing)')
  puts out3 unless st3.exitstatus == 0
end

puts($fails.empty? ? "\nALL PASS" : "\n#{$fails.size} FAILED")
exit($fails.empty? ? 0 : 1)
