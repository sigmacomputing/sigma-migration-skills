#!/usr/bin/env ruby
# test-put-layout-prune.rb — put-layout.rb must PRUNE stale injected layout
# chrome on a re-PUT (orphan-fix, class 2). Re-building a layout (e.g. after
# --rename fixed zone matching) changes the generated container set; earlier
# PUTs already injected the previous set into the live spec, and an injected
# element the new layout XML no longer references is auto-flowed by Sigma as an
# empty white card, bottom-left (live-caught: a stale "tc-<page>-extra"
# safety-net band surviving every re-PUT). Only put-layout's own injected id
# namespaces (tc-/syn-/band- containers, their -hdrtext text, dv- dividers) may
# be stale-pruned. Separately, exact versioned manual-composite ids emitted by
# build-dashboard-layout may be removed from flat document.elements. User
# elements NEVER, referenced chrome NEVER, and arbitrary missing ids remain
# fatal.
# Loopback WEBrick over http:// (same harness as test-put-layout-auth.rb) —
# offline, creds-free. Run: ruby scripts/test-put-layout-prune.rb
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

SCRIPT = File.expand_path('put-layout.rb', __dir__)

# The live spec as a PRIOR put-layout run left it: user elements + the previous
# build's injected chrome (safety-net band container, fabricated header text,
# divider) alongside chrome the new layout still uses.
LIVE_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => [
      { 'id' => 'page-pw', 'name' => 'Profitability Watch' }
    ],
    'elements' => [
      { 'id' => 'el-a', 'kind' => 'bar-chart', 'name' => 'Margin Trend' },
      { 'id' => 'title-profitability-watch', 'kind' => 'text', 'name' => nil },
      { 'id' => 'text-z9', 'kind' => 'text', 'name' => nil },              # user element, unreferenced — keep
      { 'id' => 'img-99', 'kind' => 'image', 'name' => nil },              # explicit manual-composite — prune
      { 'id' => 'band-page-pw-hdr', 'kind' => 'container' },               # still referenced — keep
      { 'id' => 'tc-page-pw-extra', 'kind' => 'container' },               # stale safety band — prune
      { 'id' => 'band-page-pw-hdrtext', 'kind' => 'text' },                # stale fabricated header — prune
      { 'id' => 'dv-page-pw-z3', 'kind' => 'divider' }                     # stale divider — prune
    ]
  }
}.freeze

# The REBUILT layout: header band + title + chart. No -extra band, no
# fabricated hdrtext, no divider.
NEW_XML = <<~XML
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-pw">
  <Container elementId="band-page-pw-hdr" type="grid" gridColumn="1 / 25" gridRow="1 / 4" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="title-profitability-watch" gridColumn="1 / 25" gridRow="1 / 4"/>
  </Container>
  <Container elementId="band-page-pw-1" type="grid" gridColumn="1 / 25" gridRow="4 / 15" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="el-a" gridColumn="1 / 25" gridRow="1 / 12"/>
    <Element elementId="text-z9" gridColumn="1 / 4" gridRow="1 / 2"/>
  </Container>
  </Page>
XML

def run_put(live_spec, prune_records)
  Dir.mktmpdir do |work|
    put_bodies = []
    srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                  Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    port = srv.config[:Port]
    srv.mount_proc('/') do |req, res|
      if req.request_method == 'GET'
        res.body = JSON.generate(live_spec)
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
    File.write(layout, NEW_XML, encoding: 'UTF-8')
    # Sidecar of the REBUILT layout — injection must stay idempotent alongside
    # both prune paths (the referenced header container is already live).
    File.write("#{layout}.elements.json", JSON.generate(
      'page-pw' => [{ 'id' => 'band-page-pw-hdr', 'kind' => 'container' },
                    { 'id' => 'band-page-pw-1', 'kind' => 'container' }]))
    File.write("#{layout}.prune-elements.json", JSON.pretty_generate(
      'version' => 1, 'elements' => prune_records))

    scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil,
              'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil, 'HOME' => work }
    out, st = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)
    [out, st, put_bodies]
  ensure
    srv&.shutdown
    th&.join
  end
end

MANUAL_COMPOSITE = [{
  'element_id' => 'img-99',
  'page_id' => 'page-pw',
  'reason' => 'manual-composite',
  'dashboard' => 'Profitability Watch',
  'zone_id' => '99'
}].freeze

out, st, put_bodies = run_put(LIVE_SPEC, MANUAL_COMPOSITE)
ok('re-PUT exits 0') { st.exitstatus == 0 }
ok('a PUT was sent') { put_bodies.length == 1 }
raw_put = put_bodies.empty? ? {} : (JSON.parse(put_bodies.first) rescue {})
# Workbook code-rep nests the document under a top-level `document` key, and
# current API writes flatten page elements into document.elements. Accept the
# legacy nested-page fallback: this test pins PRUNE behaviour, not transport.
#
# Without this unwrap `spec['pages']` was nil, so `ids` came out EMPTY — which
# made the negative "pruned" assertions pass vacuously. The envelope-sanity
# check keeps that from recurring.
spec = raw_put['document'].is_a?(Hash) ? raw_put['document'] : raw_put
els = spec['elements'] || (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
ok('the PUT body carries document pages and elements (envelope sanity)') do
  spec['pages'].is_a?(Array) && !els.empty?
end
ids = els.map { |e| e['id'] }
ok('stale injected safety-net container pruned (tc-page-pw-extra)') { !ids.include?('tc-page-pw-extra') }
ok('stale fabricated header text pruned (band-page-pw-hdrtext)') { !ids.include?('band-page-pw-hdrtext') }
ok('stale injected divider pruned (dv-page-pw-z3)') { !ids.include?('dv-page-pw-z3') }
ok('explicit manual-composite image pruned from flat document.elements') { !ids.include?('img-99') }
ok('referenced injected container kept (band-page-pw-hdr, exactly once)') { ids.count('band-page-pw-hdr') == 1 }
ok('sidecar container for the new layout injected (band-page-pw-1)') { ids.count('band-page-pw-1') == 1 }
ok('user elements never pruned — even unreferenced-looking text ids') do
  ids.include?('el-a') && ids.include?('title-profitability-watch') && ids.include?('text-z9')
end
ok('stale chrome prune is reported on stdout') { out.include?('pruned 3 stale injected layout element(s)') }
ok('explicit manual-composite prune is reported on stdout') do
  out.include?('pruned 1/1 explicit manual-composite element(s)') && out.include?('img-99')
end
ok('the new layout XML rode the PUT') { spec['layout'].to_s.include?('title-profitability-watch') }

# A prune sidecar is a narrow declaration, not permission for any other missing
# element. Add one unreferenced image that is NOT in the sidecar: final workbook
# coverage validation must abort before PUT and name it.
with_arbitrary_missing = Marshal.load(Marshal.dump(LIVE_SPEC))
with_arbitrary_missing['document']['elements'] << {
  'id' => 'img-unlisted', 'kind' => 'image', 'name' => nil
}
out2, st2, put_bodies2 = run_put(with_arbitrary_missing, MANUAL_COMPOSITE)
ok('an arbitrary unplaced element remains fatal') { st2.exitstatus != 0 }
ok('no PUT is sent when an unlisted element is missing from layout') { put_bodies2.empty? }
ok('fatal coverage error identifies the unlisted element') do
  out2.include?('layout does not place elements: img-unlisted')
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
