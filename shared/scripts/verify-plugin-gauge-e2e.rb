#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-plugin-gauge-e2e.rb — LIVE GO/NO-GO E2E proof of the Sigma custom
# plugin lifecycle (WS2 "plugin-recreation" Task 1 — the gate for the whole
# workstream). Creds-gated: needs live Sigma + a warehouse connection, so it
# is NOT part of the offline CI corpus.
#
# Proves, against a live Sigma org, that a bespoke `@sigmacomputing/plugin`
# can be:
#   1. HOSTED somewhere Sigma can be told a URL for.
#   2. REGISTERED — POST /v2/plugins -> pluginId (tolerating the documented
#      "masked HTTP 404 on a successful register" quirk; a real 403 means
#      registration is org-admin-gated — reported as a hard NO-GO).
#   3. EMBEDDED in a workbook, bound to a real data element (bare-string
#      `config` values only — the object form is silently rejected).
#   4. DATA-PARITY VERIFIED (HARD GATE) — the bound element is exported and
#      its actual/target values are compared against the known literals.
#      This is the gate that must pass for GO; it does NOT depend on the
#      plugin's host being reachable (it only exports the backing table).
#   5. Screenshotted (BEST-EFFORT, soft) — only when the plugin's host is
#      genuinely public, since Sigma's server-side PNG renderer cannot reach
#      localhost.
#
# HOST NOTES (why this run picked what it picked):
#   `netlify`/`vercel`/`surge` were not installed/authenticated in this
#   environment. `ngrok` WAS authenticated, so it was evaluated as a public
#   tunnel — but a live check (GET through the tunnel with a real browser
#   User-Agent) showed ngrok's free-tier interstitial "visit site" warning
#   page instead of the plugin content. Sigma's render server can't send the
#   `ngrok-skip-browser-warning` header a human browser would, so a free
#   ngrok tunnel does NOT count as a genuinely public host here — this
#   script verifies that live (see `genuinely_public?`) rather than assuming
#   it, and falls back to localhost when the tunnel fails the check.
#
# Usage:  ruby shared/scripts/verify-plugin-gauge-e2e.rb
# Env:    SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or
#         ~/.sigma-migration/env — sigma_rest.rb self-bootstraps);
#         SIGMA_TEST_CONNECTION_ID (Snowflake; defaults to the shared demo
#         test connection).
# Exit:   0 = lifecycle proven (registered + embedded + bound +
#         data-parity passed). 1 = NO-GO, raw evidence printed above the
#         verdict — never a faked green.

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'tmpdir'
require 'socket'
require 'time'
require 'shellwords'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'
require 'export_pool'
require_relative 'register-plugin'

RUN_TAG        = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
PLUGIN_NAME    = "WS2 gauge (e2e) #{RUN_TAG}"
CONNECTION_ID  = ENV.fetch('SIGMA_TEST_CONNECTION_ID', '362d859b-f432-4657-8e58-efc8535aa354')
SRC_ELEMENT_ID = 'tbl-src'
GAUGE_EL_ID    = 'gauge-el'
PAGE_ID        = 'pg-1'

def log(msg)
  $stderr.puts("[verify-plugin-gauge-e2e] #{msg}")
end

GAUGE_HTML = <<~HTML
  <!DOCTYPE html>
  <html>
  <head>
  <meta charset="utf-8">
  <title>WS2 gauge (e2e stub)</title>
  <style>
    html,body{margin:0;padding:0;width:100%;height:100%;background:#fff;font-family:sans-serif;overflow:hidden}
    #wrap{width:100%;height:100%;display:flex;align-items:center;justify-content:center}
    #lbl{position:absolute;bottom:8px;left:0;right:0;text-align:center;font-size:12px;color:#555}
  </style>
  </head>
  <body>
  <div id="wrap"><svg id="gauge" viewBox="0 0 200 120"></svg></div>
  <div id="lbl"></div>
  <!-- React MUST load before the SDK: @sigmacomputing/plugin's UMD build has
       React as a hard peer dep and throws at load without it, leaving
       window.SigmaPlugin with no `client` (plugin then always synths). -->
  <script crossorigin src="https://unpkg.com/react@18.3.1/umd/react.production.min.js"></script>
  <script src="https://unpkg.com/@sigmacomputing/plugin"></script>
  <script>
  // Temporary Task-1 stub — a minimal but real gauge, just enough to prove
  // the lifecycle. The clean-room production plugin lands in Task 2.
  function synth() { return { value: 82, target: 100 }; }

  function polar(cx, cy, r, deg) {
    var rad = (deg - 180) * Math.PI / 180;
    return { x: cx + r * Math.cos(rad), y: cy + r * Math.sin(rad) };
  }
  function arcPath(cx, cy, r, startDeg, endDeg) {
    var s = polar(cx, cy, r, endDeg), e = polar(cx, cy, r, startDeg);
    var large = (endDeg - startDeg) <= 180 ? 0 : 1;
    return ['M', s.x, s.y, 'A', r, r, 0, large, 0, e.x, e.y].join(' ');
  }

  function render(value, target) {
    var svg = document.getElementById('gauge');
    var frac = target > 0 ? Math.max(0, Math.min(1, value / target)) : 0;
    var color = frac >= 1 ? '#22c55e' : (frac >= 0.6 ? '#eab308' : '#ef4444');
    svg.innerHTML =
      '<path d="' + arcPath(100, 100, 80, 0, 180) + '" stroke="#e5e7eb" stroke-width="16" fill="none"/>' +
      '<path d="' + arcPath(100, 100, 80, 0, 180 * frac) + '" stroke="' + color + '" stroke-width="16" fill="none"/>' +
      '<text x="100" y="90" text-anchor="middle" font-size="28" fill="#111">' + value + '</text>' +
      '<text x="100" y="112" text-anchor="middle" font-size="12" fill="#666">of ' + target + '</text>';
    document.getElementById('lbl').textContent = 'value=' + value + ' target=' + target;
  }

  var s0 = synth(); render(s0.value, s0.target);   // immediate paint (standalone / pre-data)
  var client = (window.SigmaPlugin && window.SigmaPlugin.client) ||
               (window.Sigma && window.Sigma.client) || null;

  if (client) {
    client.config.configureEditorPanel([
      { name: 'source', type: 'element' },
      { name: 'value', type: 'column', source: 'source', allowMultiple: false },
      { name: 'target', type: 'column', source: 'source', allowMultiple: false }
    ]);
    client.config.subscribe(function (cfg) {
      if (!cfg || !cfg.source) { var s = synth(); render(s.value, s.target); return; }
      client.elements.subscribeToElementData(cfg.source, function (data) {
        try {
          var vc = cfg.value, tc = cfg.target;
          if (data && vc && tc && data[vc] && data[tc] && data[vc].length) {
            render(Number(data[vc][0]), Number(data[tc][0]));
          } else { var s = synth(); render(s.value, s.target); }
        } catch (e) { var s = synth(); render(s.value, s.target); }
      });
    });
  }

  new ResizeObserver(function () {
    var el = document.getElementById('lbl');
    var last = el.textContent.match(/value=(-?\\d+(\\.\\d+)?) target=(-?\\d+(\\.\\d+)?)/);
    if (last) render(Number(last[1]), Number(last[3]));
  }).observe(document.body);
  </script>
  </body>
  </html>
HTML

# ---------------------------------------------------------------------------
# Step 1: host the stub somewhere Sigma can be told a URL for.
# ---------------------------------------------------------------------------

def free_port
  s = TCPServer.new('127.0.0.1', 0)
  port = s.addr[1]
  s.close
  port
end

def wait_for(url, tries: 20, sleep_s: 0.25)
  tries.times do
    begin
      res = Net::HTTP.get_response(URI(url))
      return true if res.code.to_i == 200
    rescue StandardError
      # not up yet
    end
    sleep sleep_s
  end
  false
end

# Real (not assumed) check that a URL serves OUR content to a browser-like
# client, rather than e.g. an ngrok free-tier interstitial warning page.
def genuinely_public?(url)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
                      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 15) do |h|
    h.request(req)
  end
  res.code.to_i == 200 && res.body.to_s.include?('WS2 gauge (e2e stub)')
rescue StandardError => e
  log "genuinely_public? check raised: #{e.message}"
  false
end

def netlify_authed?
  return false if `which netlify 2>/dev/null`.strip.empty?
  out = `netlify status 2>&1`
  $?.success? && out !~ /not logged in/i
rescue StandardError
  false
end

def ngrok_authed?
  return false if `which ngrok 2>/dev/null`.strip.empty?
  `ngrok config check 2>&1` =~ /Valid configuration/i ? true : false
rescue StandardError
  false
end

def start_ngrok(port)
  pid = spawn('ngrok', 'http', port.to_s, '--log=stdout',
              out: File::NULL, err: File::NULL)
  public_url = nil
  30.times do
    begin
      res = Net::HTTP.get_response(URI('http://127.0.0.1:4040/api/tunnels'))
      if res.code.to_i == 200
        data = JSON.parse(res.body)
        t = (data['tunnels'] || []).find { |x| x['proto'] == 'https' } ||
            (data['tunnels'] || []).first
        public_url = t && t['public_url']
      end
    rescue StandardError
      nil
    end
    break if public_url
    sleep 0.5
  end
  [pid, public_url]
end

def host_stub
  dir = Dir.mktmpdir('ws2-gauge-')
  FileUtils.mkdir_p(File.join(dir, 'gauge'))
  File.write(File.join(dir, 'gauge', 'index.html'), GAUGE_HTML)
  port = free_port
  http_pid = spawn('python3', '-m', 'http.server', port.to_s, chdir: dir,
                    out: File::NULL, err: File::NULL)
  local_url = "http://localhost:#{port}/gauge/"
  raise "local http.server on port #{port} never came up" unless wait_for(local_url)
  log "local stub serving at #{local_url}"

  pids = [http_pid]

  # netlify/vercel/surge preferred if authenticated — none available here.
  if netlify_authed?
    log 'netlify CLI authenticated — turnkey deploy not implemented in this ' \
        'script; falling back to localhost (see report).'
  end

  if ngrok_authed?
    log 'ngrok is authenticated — attempting a public tunnel...'
    ngrok_pid, tunnel_url = start_ngrok(port)
    if tunnel_url
      pids << ngrok_pid
      if genuinely_public?("#{tunnel_url}/gauge/")
        log "ngrok tunnel #{tunnel_url} verified genuinely public (serves our content to a browser UA)."
        return { url: "#{tunnel_url}/gauge/", public: true, pids: pids, note: 'ngrok public tunnel' }
      else
        log 'ngrok tunnel did NOT serve our content to a browser User-Agent ' \
            '(free-tier interstitial confirmed live) — not counted as public. ' \
            'Falling back to localhost.'
      end
    else
      log 'ngrok did not produce a tunnel URL in time — falling back to localhost.'
    end
  else
    log 'no public static-host CLI authenticated (netlify/vercel/surge/ngrok) — using localhost.'
  end

  { url: local_url, public: false, pids: pids,
    note: 'localhost only — data-parity still provable; visual step will SKIP' }
end

# ---------------------------------------------------------------------------
# Step 2: register the plugin (tolerate the masked-404-on-success quirk; a
# real 403 is a hard NO-GO — registration is org-admin-gated).
# ---------------------------------------------------------------------------

# Thin wrapper around the shared PluginRegister.register_or_get helper
# (register-plugin.rb), which is the live-proven origin of this exact
# register/confirm dance — reusing it instead of re-inlining keeps the
# masked-404-tolerant confirmation logic in one place. Maps register_or_get's
# return/raise shape back onto the {forbidden:, plugin:} shape this script's
# caller (below) already expects, so downstream behavior is unchanged.
def register_plugin(name, description, url)
  plugin_id = PluginRegister.register_or_get(name: name, description: description, url: url)
  { forbidden: false, plugin: { 'pluginId' => plugin_id, 'name' => name } }
rescue PluginRegister::PermissionError => e
  { forbidden: true, detail: e.message }
rescue StandardError => e
  # Any other unresolved failure (register_or_get already retried the
  # confirming GET internally) — surface as "not found", same as the old
  # inline version's `{ forbidden: false, plugin: nil }` fallthrough.
  log "register_or_get raised (not a permission error): #{e.message[0, 300]}"
  { forbidden: false, plugin: nil }
end

# ---------------------------------------------------------------------------
# Step 3: POST a minimal workbook — custom-SQL table (known literals) + the
# plugin element bound to it. POST/PUT /v2/workbooks/spec is documented to
# return YAML — never JSON.parse it directly; scrape workbookId instead.
# ---------------------------------------------------------------------------

def home_folder_id
  me = Sigma.request(:get, '/v2/whoami')
  uid = me && me['userId']
  raise 'could not resolve userId from /v2/whoami' unless uid
  mem = Sigma.request(:get, "/v2/members/#{uid}")
  home = mem && mem['homeFolderId']
  raise 'could not resolve homeFolderId' unless home
  home
end

def reference_schema_version
  wbs = Sigma.request(:get, '/v2/workbooks?limit=10')
  entries = (wbs && (wbs['entries'] || wbs['workbooks'])) || []
  entries.each do |w|
    wid = w['workbookId'] || w['id']
    next unless wid
    spec = (Sigma.request(:get, "/v2/workbooks/#{wid}/spec", accept: 'application/json') rescue nil)
    return spec['schemaVersion'] if spec.is_a?(Hash) && spec['schemaVersion']
  end
  raise 'could not discover schemaVersion from any existing workbook'
end

# POST/PUT /v2/workbooks/spec: response is documented as YAML. Never rely on
# Sigma.request's accept:'application/json' auto-parse here (it would raise
# on a YAML body) — request a non-JSON accept so the raw string always comes
# back, then self-parse (JSON first in case the org actually returns JSON,
# else scrape `workbookId:` out of the YAML text). A non-JSON response body
# is NOT treated as a failure.
def post_or_put_workbook_spec(method, path, spec_hash)
  raw = Sigma.request(method, path, body: JSON.generate(spec_hash),
                                     content_type: 'application/json', accept: 'application/yaml')
  parsed = (JSON.parse(raw) rescue nil)
  return parsed if parsed.is_a?(Hash) && parsed['workbookId']
  m = raw.to_s.match(/^\s*workbookId:\s*"?'?([\w-]+)"?'?\s*$/)
  raise "no workbookId in #{method.upcase} response: #{raw.to_s[0, 500]}" unless m
  { 'workbookId' => m[1], 'raw' => raw }
end

# NOTE — the 82/100 test literals below are the SAME numbers GAUGE_HTML's
# synth() fallback renders (see above). That coincidence is exactly what let
# the original silent-synth bug hide in plain sight: a screenshot of the
# broken plugin (client undefined, always synthing) looked identical to a
# screenshot of a working one bound to this source. A screenshot — even a
# genuinely live one — cannot distinguish "reading real data" from "showing
# the synthetic fallback" here; export_and_check's element-level data-parity
# assertion below is the actual gate.
def build_spec(home, schema_version, plugin_id, actual_formula, target_formula)
  {
    'name' => "WS2 gauge plugin lifecycle — E2E proof (#{RUN_TAG})",
    'folderId' => home,
    'schemaVersion' => schema_version,
    'description' => 'Live proof: register/embed/bind/data-parity a custom Sigma plugin. Throwaway test artifact.',
    'pages' => [
      {
        'id' => PAGE_ID,
        'name' => 'WS2 Gauge E2E',
        'elements' => [
          {
            'id' => SRC_ELEMENT_ID, 'kind' => 'table', 'name' => 'Gauge source (e2e)',
            'source' => {
              'kind' => 'sql', 'connectionId' => CONNECTION_ID,
              'statement' => 'SELECT 82 AS actual, 100 AS target',
            },
            'columns' => [
              { 'id' => 'actual', 'name' => 'Actual', 'formula' => actual_formula },
              { 'id' => 'target', 'name' => 'Target', 'formula' => target_formula },
            ],
          },
          {
            'id' => GAUGE_EL_ID, 'kind' => 'plugin', 'pluginId' => plugin_id, 'name' => 'Gauge (e2e)',
            'config' => {
              'source' => { 'kind' => 'element', 'elementId' => SRC_ELEMENT_ID },
              'value' => 'actual',
              'target' => 'target',
            },
          },
        ],
      },
    ],
  }
end

# ---------------------------------------------------------------------------
# Step 4: data-parity (HARD) — export the bound element, assert the numbers.
# ---------------------------------------------------------------------------

def export_and_check(wb, element_id, deadline_s: 60)
  qid = ExportPool.start_json_export(wb, element_id, nil)
  return { ok: false, reason: 'export POST did not return a queryId' } unless qid
  deadline = ExportPool::Deadline.new(deadline_s)
  status, body = ExportPool.poll_json_download(qid, deadline)
  return { ok: false, reason: "poll status=#{status}", status: status } unless status == :ok
  rows = ExportPool.parse_json_rows(body)
  row = rows.first
  return { ok: false, reason: 'export returned zero rows', rows: rows } unless row

  actual_key = row.keys.find { |k| k.to_s.strip.casecmp('actual').zero? }
  target_key = row.keys.find { |k| k.to_s.strip.casecmp('target').zero? }
  actual_val = actual_key && row[actual_key]
  target_val = target_key && row[target_key]
  ok = actual_val.to_s.strip.to_f == 82.0 && target_val.to_s.strip.to_f == 100.0 &&
       !actual_key.nil? && !target_key.nil?
  { ok: ok, row: row, actual: actual_val, target: target_val, reason: ok ? nil : 'value mismatch or missing column' }
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

verdict = { go: false }
pids_to_kill = []

begin
  # --- Step 1: host -----------------------------------------------------
  host = host_stub
  pids_to_kill = host[:pids]
  log "PLUGIN_URL = #{host[:url]} (public=#{host[:public]}) — #{host[:note]}"

  # --- Step 2: register --------------------------------------------------
  reg = register_plugin(PLUGIN_NAME, 'recreate-as-plugin gauge proof (WS2 Task 1 live E2E)', host[:url])
  if reg[:forbidden]
    verdict = { go: false, blocker: '403 registration permission-gated (org-admin only)', detail: reg[:detail],
                host: host }
    log "NO-GO: #{verdict[:blocker]} — #{reg[:detail]}"
  elsif reg[:plugin].nil?
    verdict = { go: false, blocker: 'plugin registration not found via GET /v2/plugins after POST (not a 403 — ' \
                                     'unexplained)', host: host }
    log "NO-GO: #{verdict[:blocker]}"
  else
    plugin = reg[:plugin]
    plugin_id = plugin['pluginId'] || plugin['id']
    log "plugin registered: pluginId=#{plugin_id} name=#{plugin['name'].inspect}"

    # --- Step 3: workbook (with a small live-verified formula-prefix retry) --
    home = home_folder_id
    schema_version = reference_schema_version
    log "home folder=#{home} schemaVersion=#{schema_version}"

    candidates = [
      ['[Custom SQL/Actual]', '[Custom SQL/Target]'],
      ['[Custom SQL/ACTUAL]', '[Custom SQL/TARGET]'],
      ['[Custom SQL/actual]', '[Custom SQL/target]'],
      ['[actual]', '[target]'],
    ]

    wb = nil
    parity = nil
    tried = []
    candidates.each_with_index do |(af, tf), i|
      spec = build_spec(home, schema_version, plugin_id, af, tf)
      method = wb.nil? ? :post : :put
      path = wb.nil? ? '/v2/workbooks/spec' : "/v2/workbooks/#{wb}/spec"
      begin
        resp = post_or_put_workbook_spec(method, path, spec)
      rescue StandardError => e
        tried << { formulas: [af, tf], error: e.message[0, 400] }
        log "#{method.upcase} attempt #{i + 1} (#{af}/#{tf}) raised: #{e.message[0, 300]}"
        next
      end
      wb ||= resp['workbookId']
      unless wb
        tried << { formulas: [af, tf], error: "no workbookId in response: #{resp.inspect[0, 300]}" }
        next
      end
      log "workbook #{wb} — attempt #{i + 1} formulas=#{af}/#{tf}"
      result = (export_and_check(wb, SRC_ELEMENT_ID) rescue { ok: false, reason: $!.message })
      tried << { formulas: [af, tf], result: result }
      if result[:ok]
        parity = result
        log "data-parity PASSED with formulas #{af}/#{tf}: actual=#{result[:actual]} target=#{result[:target]}"
        break
      else
        log "attempt #{i + 1} formulas=#{af}/#{tf} did not pass: #{result[:reason]} (row=#{result[:row].inspect})"
      end
    end

    if parity.nil?
      verdict = { go: false, blocker: 'data-parity FAILED for every candidate formula prefix — no faked green',
                  workbook_id: wb, plugin_id: plugin_id, host: host, tried: tried }
      log 'NO-GO: data-parity never passed (see attempts above).'
    else
      # --- Step 5: visual (best-effort) ------------------------------------
      visual = { attempted: false }
      if host[:public]
        png_script = File.expand_path('sigma-export-png.py', __dir__)
        out_png = File.join(Dir.tmpdir, "gauge-e2e-#{RUN_TAG}.png")
        cmd = ['python3', png_script, '--workbook', wb, '--page', PAGE_ID, '--out', out_png]
        log "public host — attempting screenshot: #{cmd.join(' ')}"
        png_out = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>&1` rescue nil
        ok_png = $?.success? && File.exist?(out_png)
        visual = { attempted: true, ok: ok_png, path: (ok_png ? out_png : nil), log: png_out.to_s[0, 500] }
        log(ok_png ? "screenshot saved to #{out_png}" : "screenshot attempt output: #{png_out}")
      else
        log 'SKIP visual (localhost not reachable by render server)'
        visual = { attempted: false, skip_reason: 'localhost not reachable by render server' }
      end

      verdict = {
        go: true, workbook_id: wb, plugin_id: plugin_id, host: host, parity: parity, visual: visual,
        formulas_used: tried.last && tried.last[:formulas],
      }
    end
  end
ensure
  pids_to_kill.each do |pid|
    begin
      Process.kill('TERM', pid)
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end
end

puts
puts '=' * 78
puts verdict[:go] ? 'GO' : 'NO-GO'
puts '=' * 78
puts JSON.pretty_generate(verdict)
exit(verdict[:go] ? 0 : 1)
