#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline end-to-end test of post-and-readback.rb's gated-workspace fallback for
# NATIVE NAVIGATION BUTTONS (the default emission). A loopback WEBrick server
# stands in for Sigma: verify passes, the first workbook POST returns the real
# gate error (400 "`button` elements are not enabled for this workspace"), and
# the re-send is accepted only when no button is left in the body.
#
# Pins: the retry body carries nav.invalid text pills in place of the nav
# buttons (same ids, canonical verticalAlign, layout untouched); the actions-
# emitted manifest and the on-disk spec stop claiming the downgraded buttons as
# native actions (so build-postpublish-guide.rb lists them for manual wiring,
# exactly as it does for text-mode nav buttons, and assert-action-gates.rb's
# spec-vs-ledger action count stays consistent); a gated workspace that also
# has a writeback button still fails loudly with nothing pruned; a workspace
# that accepts buttons sees one POST and an untouched manifest.
#
# Creds-free: auth comes from <workdir>/auth.json, HOME is redirected, and
# SIGMA_ALLOW_INSECURE_BASE_URL=1 lets sigma_rest talk to the http:// loopback.
# Run: ruby scripts/test-post-gated-nav-buttons.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

$fail = 0
def ok(desc)
  r = yield
  puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"
  $fail += 1 unless r
end

SCRIPT = File.expand_path('post-and-readback.rb', __dir__)
GATE_MSG = { 'message' => '`button` elements are not enabled for this workspace' }.freeze

def nav_button(id, text, page, fill: nil)
  el = { 'id' => id, 'kind' => 'button', 'text' => text, 'appearance' => 'filled',
         'align' => 'center', 'size' => 'small',
         'actions' => [{ 'id' => "act-#{id}", 'trigger' => 'on-click',
                         'effects' => [{ 'effect' => 'navigate',
                                         'target' => { 'type' => 'page', 'page' => page } }] }] }
  el['fillColor'] = fill if fill
  el
end

INFO = { 'id' => 'btn-20', 'kind' => 'button', 'appearance' => 'text', 'text' => 'Shows weekly revenue.',
         'icon' => { 'type' => 'emoji', 'emoji' => "\u{1F4A1}" } }.freeze
WRITEBACK = { 'id' => 'btn-wb', 'kind' => 'button', 'text' => 'Save',
              'actions' => [{ 'id' => 'act-wb', 'trigger' => 'on-click',
                              'effects' => [{ 'effect' => 'set-control-value', 'control' => 'ctl-1', 'value' => 'x' }] }] }.freeze

LAYOUT = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-dash-1">
    <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 3"/>
    <Element elementId="btn-10" gridColumn="1 / 7" gridRow="3 / 5"/>
    <Element elementId="btn-11" gridColumn="7 / 13" gridRow="3 / 5"/>
    <Element elementId="btn-20" gridColumn="13 / 17" gridRow="3 / 5"/>
    <Element elementId="btn-wb" gridColumn="17 / 21" gridRow="3 / 5"/>
  </Page>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-dash-2">
    <Element elementId="title-2" gridColumn="1 / 25" gridRow="1 / 3"/>
  </Page>
XML

# The layout must place every element, so the writeback button's slot is only
# present when that element is (WorkbookCode.validate enforces both directions).
def layout_for(extra_elements)
  extra_elements.empty? ? LAYOUT.sub(%r{\s*<Element elementId="btn-wb"[^>]*/>}, '') : LAYOUT
end

def spec_doc(extra_elements)
  { 'schemaVersion' => 1, 'kind' => 'workbook', 'folderId' => 'folder-1', 'name' => 'Gated Nav',
    'pages' => [{ 'id' => 'page-dash-1', 'name' => 'Overview' },
                { 'id' => 'page-dash-2', 'name' => 'Detail View' }],
    'elements' => [
      { 'id' => 'title', 'kind' => 'text', 'body' => 'Overview' },
      { 'id' => 'title-2', 'kind' => 'text', 'body' => 'Detail' },
      nav_button('btn-10', 'Details', 'page-dash-2', fill: '#1a2b3c'),
      nav_button('btn-11', 'Elsewhere', 'page-provisional-miss'),
      INFO.dup
    ] + extra_elements,
    'layout' => layout_for(extra_elements) }
end

# Builds a workdir (spec + a manifest with two nav-button entries and one entry
# for an unrelated chart action), runs post-and-readback against a loopback
# server, and returns everything the assertions need.
def run_case(extra_elements: [], gated: true)
  Dir.mktmpdir do |work|
    posts = []
    srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                  Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    port = srv.config[:Port]
    accepted = nil
    srv.mount_proc('/') do |req, res|
      res['Content-Type'] = 'application/json'
      res.status = 200
      path = req.path
      if req.request_method == 'POST' && path == '/v2/workbooks/spec/verify'
        res.body = '{}'
      elsif req.request_method == 'POST' && path == '/v2/workbooks/spec'
        posts << req.body
        if gated && req.body.include?('"kind":"button"')
          res.status = 400
          res.body = JSON.generate(GATE_MSG)
        else
          accepted = req.body
          res.body = { 'workbookId' => 'wb-gated' }.to_json
        end
      elsif path == '/v2/workbooks/wb-gated/spec'
        res.body = accepted.to_s
      elsif path == '/v2/workbooks/wb-gated/columns'
        res.body = { 'entries' => [] }.to_json
      else
        res.status = 404
        res.body = '{}'
      end
    end
    th = Thread.new { srv.start }

    File.write(File.join(work, 'auth.json'),
               { 'SIGMA_API_TOKEN' => 'filetok', 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}" }.to_json)
    spec_path = File.join(work, 'wb-spec.json')
    original = JSON.pretty_generate(spec_doc(extra_elements))
    File.write(spec_path, original)
    manifest_path = File.join(work, 'chart-specs-actions-emitted.json')
    manifest = [
      { 'actionId' => 'act-btn-10', 'hostElementId' => 'btn-10',
        'source' => { 'kind' => 'nav-button', 'caption' => 'Details', 'actionName' => 'Overview::zone-10' },
        'targetPageName' => 'Detail View' },
      { 'actionId' => 'act-btn-11', 'hostElementId' => 'btn-11',
        'source' => { 'kind' => 'nav-button', 'caption' => 'Elsewhere', 'actionName' => 'Overview::zone-11' },
        'targetPageName' => 'Nowhere' },
      { 'actionId' => 'act-chart', 'hostElementId' => 'chart-1',
        'source' => { 'kind' => 'nav-action', 'caption' => 'Drill' } }
    ]
    File.write(manifest_path, JSON.pretty_generate(manifest))

    scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil, 'SIGMA_CLIENT_ID' => nil,
              'SIGMA_CLIENT_SECRET' => nil, 'SIGMA_ORCHESTRATED_RUN' => '1', 'HOME' => work,
              # the loopback server speaks plain http; sigma_rest refuses that without this opt-out
              'SIGMA_ALLOW_INSECURE_BASE_URL' => '1' }
    out, st = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work), RbConfig.ruby, SCRIPT,
                              '--type', 'workbook', '--spec', spec_path, '--out', File.join(work, 'ids.json'),
                              '--workdir', work, '--skip-style-normalize', 'unit-test')
    {
      out: out, status: st, posts: posts.map { |b| JSON.parse(b) },
      manifest: JSON.parse(File.read(manifest_path)), spec: JSON.parse(File.read(spec_path)),
      original: JSON.parse(original)
    }
  ensure
    srv&.shutdown
    th&.join
  end
end

def elements_of(body)
  (body['document'] || body)['elements']
end

puts 'case 1 — gated workspace, nav + info-icon buttons only'
r = run_case
ok('exits 0 (the re-send was accepted)') { r[:status].exitstatus == 0 }
ok('exactly two workbook POSTs: the gated one and the re-send') { r[:posts].size == 2 }
first = r[:posts][0] ? elements_of(r[:posts][0]) : []
retry_els = r[:posts][1] ? elements_of(r[:posts][1]) : []
ok('first POST carried native buttons (sanity)') { first.count { |e| e['kind'] == 'button' } == 3 }
ok('the re-send carries no button element at all') { retry_els.none? { |e| e['kind'] == 'button' } }
pill10 = retry_els.find { |e| e['id'] == 'btn-10' } || {}
pill11 = retry_els.find { |e| e['id'] == 'btn-11' } || {}
ok('resolved nav button becomes a text pill with the same id, linking the page NAME, fill carried') do
  pill10['kind'] == 'text' &&
    pill10['body'] == '<p style="text-align: center"><span style="background-color: #1a2b3c">' \
                      '[**Details**](https://nav.invalid/#page=Detail%20View)</span></p>'
end
ok('unresolved page id falls back to the button text as the page name') do
  pill11['body'] == '<p style="text-align: center">[**Elsewhere**](https://nav.invalid/#page=Elsewhere)</p>'
end
ok('pill verticalAlign is the canonical spelling after the re-wrap (center, not the legacy middle)') do
  pill10['verticalAlign'] == 'center' && pill11['verticalAlign'] == 'center'
end
ok('pills have no actions key') { !pill10.key?('actions') && !pill11.key?('actions') }
ok('info-icon button became inline text (existing behaviour unchanged)') do
  (retry_els.find { |e| e['id'] == 'btn-20' } || {})['body'] == "\u{1F4A1} Shows weekly revenue."
end
ok('layout and pages ride through the re-send untouched') do
  r[:posts][1] && r[:posts][1]['document']['layout'] == layout_for([]) && r[:posts][1]['document']['pages'].size == 2
end
ok('exactly one WARN names the rewrite, with the ids and what each became') do
  warns = r[:out].lines.grep(/WARN: this workspace rejects button elements/)
  warns.size == 1 && warns[0].include?('btn-10') && warns[0].include?('btn-11') && warns[0].include?('btn-20') &&
    warns[0].include?('"Detail View"') && warns[0].include?('unresolved')
end
ok('manifest keeps only the unrelated chart action') do
  r[:manifest].map { |m| m['actionId'] } == ['act-chart']
end
ok('the on-disk spec now matches what was posted (no native button left)') do
  els = r[:spec]['elements']
  els.none? { |e| e['kind'] == 'button' } && els.find { |e| e['id'] == 'btn-10' }['body'].include?('nav.invalid')
end
ok('no action remains in the on-disk spec (assert-action-gates compares its action count to the pruned manifest)') do
  r[:spec]['elements'].sum { |e| Array(e['actions']).size } == 0
end

puts 'case 2 — gated workspace that ALSO has a writeback button: still fails loudly, nothing pruned'
r = run_case(extra_elements: [WRITEBACK.dup])
ok('exits non-zero') { r[:status].exitstatus != 0 }
ok('two POSTs (the retry still carried the writeback button)') { r[:posts].size == 2 }
ok('manifest untouched') { r[:manifest].size == 3 }
ok('on-disk spec untouched') { r[:spec] == r[:original] }

puts 'case 3 — workspace that accepts buttons: one POST, native buttons, manifest untouched'
r = run_case(gated: false)
ok('exits 0') { r[:status].exitstatus == 0 }
ok('a single POST with native buttons') do
  r[:posts].size == 1 && elements_of(r[:posts][0]).count { |e| e['kind'] == 'button' } == 3
end
ok('manifest untouched') { r[:manifest].size == 3 }
ok('on-disk spec untouched') { r[:spec] == r[:original] }
ok('no gate WARN') { !r[:out].include?('rejects button elements') }

puts
puts($fail.zero? ? 'all gated-nav-button post tests passed' : "#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
