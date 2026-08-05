#!/usr/bin/env ruby
# Offline test (bead tt3z.14): put-layout.rb must read the Sigma token from
# <WORK>/auth.json via lib/sigma_rest — NOT ENV.fetch('SIGMA_API_TOKEN') — so it
# no longer KeyError-crashes at load when the token lives only in auth.json (the
# field-caught friction that forced a manual token-export + a /c/ path failure).
# Loopback WEBrick over http:// (put-layout's http helper now derives TLS from the
# URL scheme), no creds, no network.
require 'webrick'
require 'json'
require 'tmpdir'
require 'open3'

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

SCRIPT = File.expand_path('put-layout.rb', __dir__)

Dir.mktmpdir do |work|
  captured = { get_auth: nil, saw_put: false }
  srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
  port = srv.config[:Port]
  srv.mount_proc('/') do |req, res|
    if req.request_method == 'GET'
      captured[:get_auth] ||= req['authorization']
      res.body = { 'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [] }] }.to_json
    else # PUT
      captured[:saw_put] = true
      res.body = { 'workbookId' => 'wb-test' }.to_json
    end
    res['Content-Type'] = 'application/json'
    res.status = 200
  end
  th = Thread.new { srv.start }

  File.write(File.join(work, 'auth.json'),
             { 'SIGMA_API_TOKEN' => 'filetok', 'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}" }.to_json)
  layout = File.join(work, 'layout.xml')
  File.write(layout, "<Layout><Zone/></Layout>", encoding: 'UTF-8')

  # Scrub the env AND redirect HOME so sigma_rest's ~/.sigma-migration/env neutral
  # bootstrap (real creds on a dev box) can't leak in — the token+base must come
  # ONLY from <WORK>/auth.json.
  scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil,
            'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil, 'HOME' => work }

  # (1) token in auth.json only — must load it, PUT, exit 0
  out1, st1 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)
  ok('exit 0 with token only in auth.json (no KeyError at load)') { st1.exitstatus == 0 }
  ok('GET carried "Bearer filetok" — token came from auth.json, not ENV') { captured[:get_auth] == 'Bearer filetok' }
  ok('reached the PUT (full flow)') { captured[:saw_put] }
  puts out1 unless st1.exitstatus == 0

  # (2) no token anywhere (no auth.json, no env, no client creds) — must fail LOUD, not silently pass
  Dir.mktmpdir do |empty|
    layout2 = File.join(empty, 'layout.xml'); File.write(layout2, "<Layout/>", encoding: 'UTF-8')
    _o2, st2 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => empty, 'HOME' => empty),
                               'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout2)
    ok('no token anywhere → non-zero exit (fail-loud, never silent-pass)') { st2.exitstatus != 0 }
  end

  srv.shutdown
  th.join
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
