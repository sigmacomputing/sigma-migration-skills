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
  captured = { get_auth: nil, saw_put: false, gets: [], expire_old: false, expire_all: false }
  srv = WEBrick::HTTPServer.new(Port: 0, BindAddress: '127.0.0.1',
                                Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
  port = srv.config[:Port]
  srv.mount_proc('/') do |req, res|
    if req.request_method == 'GET'
      captured[:get_auth] ||= req['authorization']
      captured[:gets] << req['authorization']
      if captured[:expire_all] || (captured[:expire_old] && req['authorization'] == 'Bearer filetok')
        res.status = 401
        res.body = '{"code":"unauthorized"}'
        next
      end
      res.body = {
        'document' => {
          'schemaVersion' => 1,
          'kind' => 'workbook',
          'pages' => [{ 'id' => 'p1', 'name' => 'P' }],
          'elements' => [],
          'layout' => '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1"></Page>'
        }
      }.to_json
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
  File.write(layout,
             '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1"></Page>',
             encoding: 'UTF-8')

  # Scrub the env AND redirect HOME so sigma_rest's ~/.sigma-migration/env neutral
  # bootstrap (real creds on a dev box) can't leak in — the token+base must come
  # ONLY from <WORK>/auth.json.
  # Token-age and route keys are scrubbed too: a shell that ran browser-login.sh
  # exports SIGMA_TOKEN_MINTED_AT, which would make auth.json's token look stale.
  scrub = { 'SIGMA_API_TOKEN' => nil, 'SIGMA_BASE_URL' => nil,
            'SIGMA_CLIENT_ID' => nil, 'SIGMA_CLIENT_SECRET' => nil,
            'SIGMA_TOKEN_MINTED_AT' => nil, 'SIGMA_AUTH_METHOD' => nil,
            'SIGMA_TOKEN_PROVIDER' => nil, 'SIGMA_AUTH_MODE' => nil,
            'SIGMA_CLI_PROFILE' => nil, 'SIGMA_CLI_PROFILE_FROM_FILE' => nil,
            'HOME' => work }

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
    # A blank base URL makes the shared client ask the token provider, so pin one
    # that always fails: a developer's signed-in Sigma CLI must not answer here.
    dead = File.join(empty, 'dead-provider.py')
    File.write(dead, "raise SystemExit('offline test: no Sigma credentials')\n")
    _o2, st2 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => empty, 'HOME' => empty,
                                           'SIGMA_TOKEN_PROVIDER' => dead),
                               'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout2)
    ok('no token anywhere → non-zero exit (fail-loud, never silent-pass)') { st2.exitstatus != 0 }
  end

  # (3) 401 mid-run with NO SIGMA_CLIENT_ID (CLI-profile / browser run): the
  # helper must re-mint once through the shared provider and retry. A stub token
  # provider stands in for the CLI; it records each call.
  provider = File.join(work, 'provider.py')
  calls = File.join(work, 'provider-calls')
  File.write(provider, <<~PY)
    with open(#{calls.inspect}, 'a') as fh:
        fh.write('x')
    print('export SIGMA_API_TOKEN=newtok')
    print('export SIGMA_AUTH_METHOD=sigma-cli')
  PY
  captured.update(expire_old: true, saw_put: false, gets: [])
  out3, st3 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work, 'SIGMA_TOKEN_PROVIDER' => provider),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)
  ok('401 without SIGMA_CLIENT_ID: refreshed via the provider and retried (exit 0)') { st3.exitstatus == 0 }
  ok('retry carried the re-minted token, exactly one retry') { captured[:gets] == ['Bearer filetok', 'Bearer newtok'] }
  ok('provider invoked exactly once') { File.exist?(calls) && File.read(calls) == 'x' }
  puts out3 unless st3.exitstatus == 0

  # (4) provider failure on the refresh: no crash inside the refresh, the 401 is
  # returned (script then fails on the non-spec body), and there is no retry loop.
  File.write(provider, "import sys\nsys.stderr.write('provider down')\nsys.exit(1)\n")
  File.delete(calls) if File.exist?(calls)
  captured.update(gets: [])
  out4, st4 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work, 'SIGMA_TOKEN_PROVIDER' => provider),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)
  ok('failed refresh: single GET, no retry, non-zero exit') { captured[:gets] == ['Bearer filetok'] && st4.exitstatus != 0 }
  ok('failed refresh does not surface an AuthError backtrace from the refresh') { !out4.include?('AuthError') }
  ok('failed refresh warns with the provider error (first line)') { out4.include?('[auth] token refresh failed:') }
  ok('401 after a failed refresh is reported as an auth failure, not an invalid layout') do
    out4.include?('Sigma auth failed') && !out4.include?('invalid workbook layout')
  end

  # (5) the server rejects EVERY token (even the re-minted one): exactly one
  # refresh and one retry, then the 401 is returned. Never a retry loop.
  File.write(provider, <<~PY)
    with open(#{calls.inspect}, 'a') as fh:
        fh.write('x')
    print('export SIGMA_API_TOKEN=newtok')
    print('export SIGMA_AUTH_METHOD=sigma-cli')
  PY
  File.delete(calls) if File.exist?(calls)
  captured.update(gets: [], expire_all: true)
  out5, st5 = Open3.capture2e(scrub.merge('SIGMA_WORKDIR' => work, 'SIGMA_TOKEN_PROVIDER' => provider),
                              'ruby', SCRIPT, '--workbook', 'wb-test', '--layout', layout)
  ok('always-401 server: exactly two GETs (original + one retry)') { captured[:gets] == ['Bearer filetok', 'Bearer newtok'] }
  ok('always-401 server: provider invoked exactly once') { File.exist?(calls) && File.read(calls) == 'x' }
  ok('always-401 server: non-zero exit') { st5.exitstatus != 0 }
  captured[:expire_all] = false

  srv.shutdown
  th.join
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
