#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression tests for tableau-discover.rb's fetch contract (offline, stubbed).
#
# (A) OPT-IN extract re-fetch (B6 default flip). tableau-discover.rb can
# re-download workbook content WITH includeExtract=true when extract markers
# are present but the thin download carried no .hyper — the heaviest task in
# discovery, and whose payload only extract-landing routes ever consume.
# Contract under test: the re-fetch is SKIPPED by default with one clear
# breadcrumb naming the opt-in flag; --extract-refetch opts in (attempts still
# capped at 2); the old opt-out spelling --no-extract-refetch stays accepted
# (migrate-tableau.rb passes it on the --skip-extract-landing live repoint).
#
# (B) BOUNDED downloads (W2.21/E6.4). Net read_timeout never trips on a
# trickling response (bytes keep arriving), so the download tasks carry
# wall-clock budgets. Contract: a trickle-wedged extract re-fetch is abandoned
# within its budget on ONE attempt (never retried into a 4x burn), discovery
# proceeds thin with a WARN and exits 0; an over-ceiling Get-Workbook size
# PRE-ABORTS the fetch before the first byte, naming --download-budget; an
# explicit --download-budget disables the pre-abort; default budgets never
# false-trip a fast fetch.
#
# (C) SCOPED CSVs + dedicated PNG worker (W2.20) — see the checks below.
#
# Proven with a STUBBED Tableau lib (the script + its real zip/fcp libs are
# copied to a tmpdir whose lib/ carries a stub tableau_rest.rb, so no network
# is possible): the stub serves a thin .twb with extract markers, fails the
# extract re-fetch retryably (or trickles, or reports a huge size — ENV
# switches), and logs every fetch. Offline.
#
# Usage: ruby scripts/test-discover-extract-skip.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

DIR = __dir__
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

STUB = <<~'RUBY'
  # Stub Tableau REST: no network, every fetch appended to STUB_FETCH_LOG.
  # Classic method defs on purpose — the skills target Ruby 2.6.
  require 'json'
  module Tableau
    class Error < StandardError; end
    def self.rec(line)
      File.open(ENV.fetch('STUB_FETCH_LOG'), 'a') { |f| f.puts(line) }
    end
    def self.get_workbook(id)
      # STUB_VIEWS='Sheet A,Sheet B' => views v0..vN in order (W2.20 tests).
      views = ENV['STUB_VIEWS'].to_s.split(',').each_with_index.map do |n, i|
        { 'id' => "v#{i}", 'name' => n }
      end
      wb = { 'id' => id, 'views' => { 'view' => views } }
      wb['size'] = ENV['STUB_WB_SIZE'] if ENV['STUB_WB_SIZE'] # MB, per Get Workbook
      wb
    end
    def self.graphql_workbook_dashboards(_luid)
      if ENV['STUB_MEMBERSHIP_HANG']
        # Wedged Metadata API: the response never completes and bytes keep
        # "arriving", so only the membership wall-clock budget can end this.
        # Sleeps in slices for ~30s; the budget must interrupt long before.
        150.times { sleep 0.2 }
        raise Error, 'stub membership hang ran to completion — budget never fired'
      end
      # Flaking Metadata API: RETRYABLE (502) failure on every attempt.
      raise Error, '502 stub: metadata api flaking' if ENV['STUB_MEMBERSHIP_502']
      # Metadata API off/unindexed unless the test provides membership JSON.
      raise Error, 'stub: metadata api unavailable' unless ENV['STUB_MEMBERSHIP']
      JSON.parse(ENV['STUB_MEMBERSHIP'])
    end
    def self.find_workbook_by_name(_n)
      { 'id' => 'wb-stub' }
    end
    def self.capabilities
      {}
    end
    def self.download_workbook_content(_id, include_extract: false)
      rec("download include_extract=#{include_extract}")
      if include_extract
        if ENV['STUB_TRICKLE']
          # Trickle wedge: bytes keep dribbling (1 byte/s-shaped), so the
          # socket read timeout never fires — only a wall-clock budget can end
          # this. Sleeps in small slices for ~30s; the budget must interrupt.
          150.times { sleep 0.2 }
          raise Error, 'stub trickle ran to completion — budget never fired'
        end
        # otherwise fail RETRYABLY (502) every time.
        raise Error, '502 stub: extract payload unavailable'
      end
      if ENV['STUB_TWB_DASH']
        # Dashboards + zones + worksheets for the membership pre-parse tests.
        return "<workbook><worksheets><worksheet name='Sheet A'/>" \
               "<worksheet name='Sheet B'/><worksheet name='Sheet C'/></worksheets>" \
               "<dashboards><dashboard name='Overview'><zones>" \
               "<zone id='1' name='Sheet A'/><zone id='2' name='Sheet B'/>" \
               "<zone id='3' name='Some Text Zone'/></zones></dashboard>" \
               "<dashboard name='Detail'><zones><zone id='4' name='Sheet C'/></zones>" \
               "</dashboard></dashboards></workbook>"
      end
      "<workbook><datasources><datasource caption=''><extract count='1'/></datasource></datasources></workbook>"
    end
    def self.view_image(id, resolution: nil)
      rec("png #{id}")
      sleep ENV['STUB_SLOW_PNG'].to_f if ENV['STUB_SLOW_PNG'] # render takes a while
      'PNGBYTES'
    end
    def self.view_data(id)
      rec("csv #{id}")
      sleep ENV['STUB_SLOW_CSV_S'].to_f if ENV['STUB_SLOW_CSV'] == id # one wedged export
      "h\n1\n"
    end
    def self.read_metadata(_l); nil; end
    def self.graphql_datasource_fields(_l); nil; end
    def self.find_datasource_by_name(_n); nil; end
    def self.refresh_token!; nil; end
  end
RUBY

def run_discover(script, out_dir, log_path, *extra, env: {}, images: false)
  base = { 'STUB_FETCH_LOG' => log_path }
  cmd = [RbConfig.ruby, script, '--workbook-id', 'wb-stub', '--out', out_dir]
  cmd << '--skip-images' unless images
  cmd += extra
  out = IO.popen(base.merge(env), cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

def timings(out_dir)
  JSON.parse(File.read(File.join(out_dir, 'timings.json')))
rescue StandardError
  nil
end

Dir.mktmpdir do |tmp|
  # Copy the script + the real libs it needs; the stub REPLACES tableau_rest.rb
  # (tableau-discover.rb resolves its lib/ relative to its own location).
  FileUtils.mkdir_p(File.join(tmp, 'lib'))
  script = File.join(tmp, 'tableau-discover.rb')
  FileUtils.cp(File.join(DIR, 'tableau-discover.rb'), script)
  %w[zip_extract.rb fcp_normalize.rb].each do |l|
    FileUtils.cp(File.join(DIR, 'lib', l), File.join(tmp, 'lib', l))
  end
  File.write(File.join(tmp, 'lib', 'tableau_rest.rb'), STUB)

  # (1) DEFAULT + extract route: NO re-fetch, one skip line naming the opt-in.
  log1 = File.join(tmp, 'fetch1.log')
  File.write(log1, '')
  code, out = run_discover(script, File.join(tmp, 'out1'), log1)
  fetches = File.readlines(log1).map(&:strip)
  check(code == 0, "default run completes (exit #{code})", fails)
  check(fetches.count('download include_extract=false') == 1, 'thin download fetched once by default', fails)
  n_extract = fetches.count('download include_extract=true')
  check(n_extract.zero?, "NO extract re-fetch by default (got #{n_extract} includeExtract=true fetches)", fails)
  skip_lines = out.lines.grep(/extract re-fetch SKIPPED/)
  check(skip_lines.size == 1, "exactly one clear skip line by default (got #{skip_lines.size})", fails)
  check(out.include?('--extract-refetch'), 'default skip line names the opt-in flag', fails)

  # (2) --extract-refetch: re-fetch attempted, still CAPPED at 2 attempts.
  log2 = File.join(tmp, 'fetch2.log')
  File.write(log2, '')
  code, out = run_discover(script, File.join(tmp, 'out2'), log2, '--extract-refetch')
  fetches = File.readlines(log2).map(&:strip)
  check(code == 0, "--extract-refetch run completes (exit #{code})", fails)
  n_extract = fetches.count('download include_extract=true')
  check(n_extract == 2, "--extract-refetch attempts the re-fetch, CAPPED at 2 (got #{n_extract})", fails)
  check(out.include?('re-fetching WITH includeExtract=true'), '--extract-refetch announces the re-fetch', fails)

  # (3) --no-extract-refetch (old opt-out spelling) stays accepted: no fetch,
  # skip line still logged.
  log3 = File.join(tmp, 'fetch3.log')
  File.write(log3, '')
  code, out = run_discover(script, File.join(tmp, 'out3'), log3, '--no-extract-refetch')
  fetches = File.readlines(log3).map(&:strip)
  check(code == 0, "--no-extract-refetch still accepted (exit #{code})", fails)
  check(fetches.count('download include_extract=true').zero?, 'no extract fetch under --no-extract-refetch', fails)
  check(out.lines.grep(/extract re-fetch SKIPPED/).size == 1, 'skip line still logged under --no-extract-refetch', fails)

  # ---- (B) W2.21 bounded downloads ----------------------------------------

  # (B1) TRICKLE TRIP: a dribbling extract re-fetch is abandoned within the
  # wall-clock budget, on ONE attempt, thin-.twb WARN, exit 0.
  log4 = File.join(tmp, 'fetch4.log')
  File.write(log4, '')
  t0 = Time.now
  code, out = run_discover(script, File.join(tmp, 'out4'), log4,
                           '--extract-refetch', '--download-budget', '2',
                           env: { 'STUB_TRICKLE' => '1' })
  wall = Time.now - t0
  fetches = File.readlines(log4).map(&:strip)
  check(code == 0, "trickle run still exits 0 — fail-open (exit #{code})", fails)
  check(wall < 20, "trickle abandoned within budget (wall #{wall.round(1)}s < 20s, budget 2s)", fails)
  check(fetches.count('download include_extract=true') == 1,
        'blown budget is NOT retried — exactly one extract attempt', fails)
  check(out.include?('proceeding with the thin .twb'), 'thin-.twb WARN logged on abandon', fails)
  tj = timings(File.join(tmp, 'out4'))
  task = tj && (tj['tasks'] || []).find { |t| t['task'] == 'twb-download-extract' }
  check(task && task['ok'] == false && task['error'].to_s =~ /budget/,
        "timings.json records the budget failure (got #{task ? task['error'].inspect : 'no task'})", fails)
  check(task && task['attempts'] == 1, 'timings.json shows a single attempt', fails)

  # (B2) SIZE PRE-ABORT: an over-ceiling Get Workbook size stops the fetch
  # BEFORE the first byte and names the override.
  log5 = File.join(tmp, 'fetch5.log')
  File.write(log5, '')
  code, out = run_discover(script, File.join(tmp, 'out5'), log5, '--extract-refetch',
                           env: { 'STUB_WB_SIZE' => '5000' })
  fetches = File.readlines(log5).map(&:strip)
  check(code == 0, "pre-abort run exits 0 (exit #{code})", fails)
  check(fetches.count('download include_extract=true').zero?,
        'pre-abort fires BEFORE the first byte (no includeExtract=true fetch)', fails)
  check(out =~ /PRE-ABORTED/, 'pre-abort is stated, not silent', fails)
  check(out.include?('--download-budget'), 'pre-abort names the --download-budget override', fails)

  # (B3) EXPLICIT OVERRIDE beats the pre-abort: operator budget is the budget.
  log6 = File.join(tmp, 'fetch6.log')
  File.write(log6, '')
  code, out = run_discover(script, File.join(tmp, 'out6'), log6,
                           '--extract-refetch', '--download-budget', '9999',
                           env: { 'STUB_WB_SIZE' => '5000' })
  fetches = File.readlines(log6).map(&:strip)
  check(code == 0, "override run exits 0 (exit #{code})", fails)
  check(out !~ /PRE-ABORTED/, 'no pre-abort under an explicit --download-budget', fails)
  check(fetches.count('download include_extract=true') == 2,
        'override fetch attempted (retryable stub failure still capped at 2)', fails)

  # (B4) NO FALSE TRIP: the default budgets never clip a fast fetch — the
  # default run's thin download succeeded first try under the 180s budget.
  tj1 = timings(File.join(tmp, 'out1'))
  dl = tj1 && (tj1['tasks'] || []).find { |t| t['task'] == 'twb-download' }
  check(dl && dl['ok'] == true && dl['attempts'] == 1,
        'default budgets: fast thin download untouched (ok, one attempt)', fails)

  # ---- (C) W2.20 scoped CSV fetch ------------------------------------------

  stub_views = 'Sheet A,Sheet B,Sheet C,Overview,Detail' # => v0..v4
  membership = JSON.generate([
    { 'name' => 'Overview', 'sheets' => [{ 'name' => 'Sheet A', 'luid' => 'v0' },
                                         { 'name' => 'Sheet B', 'luid' => 'v1' }] },
    { 'name' => 'Detail',   'sheets' => [{ 'name' => 'Sheet C', 'luid' => 'v2' }] }
  ])
  csvs_of = ->(log_file) { File.readlines(log_file).map(&:strip).select { |l| l.start_with?('csv ') } }

  # (C1) SCOPE TRIP via Metadata API at t≈0: only the target dashboard's
  # member-sheet CSVs are fetched, and the scoping is stated with its source.
  log7 = File.join(tmp, 'fetch7.log')
  File.write(log7, '')
  code, out = run_discover(script, File.join(tmp, 'out7'), log7, '--dashboard', 'Overview',
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_MEMBERSHIP' => membership })
  check(code == 0, "scoped (metadata-api) run exits 0 (exit #{code})", fails)
  check(csvs_of.call(log7).sort == ['csv v0', 'csv v1'],
        "metadata-api scope fetches ONLY member-sheet CSVs (got #{csvs_of.call(log7).sort.inspect})", fails)
  check(out.include?('membership: metadata-api'), 'scope line states the metadata-api source', fails)

  # (C2) SCOPE TRIP via .twb pre-parse when the Metadata API has no answer:
  # membership resolves as soon as the .twb lands; text zones drop out.
  log8 = File.join(tmp, 'fetch8.log')
  File.write(log8, '')
  code, out = run_discover(script, File.join(tmp, 'out8'), log8, '--dashboard', 'Overview',
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_TWB_DASH' => '1' })
  check(code == 0, "scoped (twb-preparse) run exits 0 (exit #{code})", fails)
  check(csvs_of.call(log8).sort == ['csv v0', 'csv v1'],
        "twb pre-parse scope fetches ONLY member-sheet CSVs (got #{csvs_of.call(log8).sort.inspect})", fails)
  check(out.include?('membership: twb-preparse'), 'scope line states the twb-preparse source', fails)

  # (C3) FAIL-OPEN: membership unresolvable from BOTH sources → ALL view CSVs,
  # stated not silent. Scoping may only ever REMOVE fetches when confident.
  log9 = File.join(tmp, 'fetch9.log')
  File.write(log9, '')
  code, out = run_discover(script, File.join(tmp, 'out9'), log9, '--dashboard', 'Overview',
                           env: { 'STUB_VIEWS' => stub_views })
  check(code == 0, "fail-open run exits 0 (exit #{code})", fails)
  check(csvs_of.call(log9).size == 5,
        "unresolvable membership fetches ALL 5 view CSVs (got #{csvs_of.call(log9).size})", fails)
  check(out =~ /UNRESOLVABLE/ && out.include?('fail-open'), 'fail-open is stated, not silent', fails)

  # (C4) UNSCOPED runs are untouched: no --dashboard → all views, no scope lines.
  log10 = File.join(tmp, 'fetch10.log')
  File.write(log10, '')
  code, out = run_discover(script, File.join(tmp, 'out10'), log10,
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_MEMBERSHIP' => membership })
  check(code == 0, "unscoped run exits 0 (exit #{code})", fails)
  check(csvs_of.call(log10).size == 5, 'unscoped run still fetches every view CSV', fails)
  check(!out.include?('scope:'), 'no scope chatter on unscoped runs', fails)

  # (C5) BOGUS TARGET fails open, never silently narrows: an unmatched
  # --dashboard name (typo) must not drop CSVs on the floor.
  log11 = File.join(tmp, 'fetch11.log')
  File.write(log11, '')
  code, out = run_discover(script, File.join(tmp, 'out11'), log11, '--dashboard', 'No Such Dash',
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_MEMBERSHIP' => membership, 'STUB_TWB_DASH' => '1' })
  check(code == 0, "bogus-target run exits 0 (exit #{code})", fails)
  check(csvs_of.call(log11).size == 5,
        "bogus --dashboard target fetches ALL view CSVs (got #{csvs_of.call(log11).size})", fails)
  check(out =~ /UNRESOLVABLE/, 'bogus target is reported unresolvable', fails)

  # (C6) MEMBERSHIP BUDGET TRIP (fix pass): the dashboard-membership probe runs
  # SERIALLY before the pool, so a wedged Metadata API must be abandoned within
  # the probe's own wall-clock budget on ONE attempt (non-retryable message),
  # after which scoping still resolves via the .twb pre-parse and the run
  # completes. Net read timeouts never fire on a hang that dribbles — only the
  # budget can end it.
  retryable = /\b(429|408|400|50[234])\b|Too Many Requests|timed? ?out|Timeout/i # mirrors RETRYABLE
  log14 = File.join(tmp, 'fetch14.log')
  File.write(log14, '')
  t0 = Time.now
  code, out = run_discover(script, File.join(tmp, 'out14'), log14, '--dashboard', 'Overview',
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_TWB_DASH' => '1',
                                  'STUB_MEMBERSHIP_HANG' => '1', 'TABLEAU_MEMBERSHIP_BUDGET' => '2' })
  wall = Time.now - t0
  check(code == 0, "membership-hang run exits 0 — fail-open (exit #{code})", fails)
  check(wall < 20, "wedged membership probe abandoned within budget (wall #{wall.round(1)}s < 20s, budget 2s)", fails)
  check(csvs_of.call(log14).sort == ['csv v0', 'csv v1'],
        ".twb pre-parse still scopes after the probe trips (got #{csvs_of.call(log14).sort.inspect})", fails)
  check(out.include?('membership: twb-preparse'), 'post-trip scope line states the twb-preparse source', fails)
  tj14 = timings(File.join(tmp, 'out14'))
  probe = tj14 && (tj14['tasks'] || []).find { |t| t['task'] == 'dashboard-membership' }
  check(probe && probe['ok'] == false && probe['attempts'] == 1 &&
        probe['error'].to_s =~ /membership budget/ && probe['error'].to_s !~ retryable,
        'blown membership budget abandoned on ONE attempt, non-retryable message in timings.json ' \
        "(got #{probe ? [probe['attempts'], probe['error']].inspect : 'no task'})", fails)

  # (C7) NO FALSE TRIP: the default membership budget never clips a healthy
  # probe — C1's metadata-api resolution succeeded first try under it.
  tj7 = timings(File.join(tmp, 'out7'))
  mp = tj7 && (tj7['tasks'] || []).find { |t| t['task'] == 'dashboard-membership' }
  check(mp && mp['ok'] == true && mp['attempts'] == 1,
        'default membership budget: healthy probe untouched (ok, one attempt)', fails)

  # (C8) RETRYABLE CAP: a flaking (502) Metadata API burns at most ONE backoff
  # before the pool starts — the probe is capped at 2 attempts, then fails
  # open to the .twb pre-parse.
  log15 = File.join(tmp, 'fetch15.log')
  File.write(log15, '')
  code, out = run_discover(script, File.join(tmp, 'out15'), log15, '--dashboard', 'Overview',
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_TWB_DASH' => '1',
                                  'STUB_MEMBERSHIP_502' => '1' })
  check(code == 0, "membership-flake run exits 0 — fail-open (exit #{code})", fails)
  check(csvs_of.call(log15).sort == ['csv v0', 'csv v1'],
        ".twb pre-parse still scopes after the flaking probe (got #{csvs_of.call(log15).sort.inspect})", fails)
  tj15 = timings(File.join(tmp, 'out15'))
  fp = tj15 && (tj15['tasks'] || []).find { |t| t['task'] == 'dashboard-membership' }
  check(fp && fp['ok'] == false && fp['attempts'] == 2,
        "flaking membership probe capped at 2 attempts (got #{fp ? fp['attempts'].inspect : 'no task'})", fails)

  # ---- (D) W2.20 dedicated PNG worker --------------------------------------

  span_of = ->(tj, name) { (tj['tasks'] || []).find { |t| t['task'] == name } }

  # (D1) Images run on a dedicated worker from t≈0 and OVERLAP the CSV pool:
  # with one wedged CSV export (2.5s), the dashboards/ PNG (enqueued when the
  # .twb lands) must START before that CSV ENDS — the old serial-after-drain
  # pass could not. The views/<id>.png fetched this run is REUSED for its
  # dashboards/ twin instead of re-rendering.
  log12 = File.join(tmp, 'fetch12.log')
  File.write(log12, '')
  code, out = run_discover(script, File.join(tmp, 'out12'), log12, images: true,
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_TWB_DASH' => '1',
                                  'STUB_SLOW_CSV' => 'v2', 'STUB_SLOW_CSV_S' => '2.5' })
  check(code == 0, "png-worker run exits 0 (exit #{code})", fails)
  check(File.exist?(File.join(tmp, 'out12', 'dashboards', 'Overview.png')) &&
        File.exist?(File.join(tmp, 'out12', 'dashboards', 'Detail.png')),
        'both dashboards/ PNGs written', fails)
  check(out.include?('reused views/v3.png'),
        'heuristic view PNG reused for its dashboards/ twin (no re-render)', fails)
  tj12 = timings(File.join(tmp, 'out12'))
  heur = tj12 && span_of.call(tj12, 'png:Overview')
  check(heur && heur['start'] < 1.0,
        "heuristic PNG starts at t≈0 on the image worker (start #{heur && heur['start']})", fails)
  slow = tj12 && span_of.call(tj12, 'csv:Sheet C')
  dpng = tj12 && span_of.call(tj12, 'dashboard-png:Detail')
  check(slow && dpng && dpng['start'] < slow['start'] + slow['seconds'],
        "dashboards/ PNG overlaps the CSV pool (png start #{dpng && dpng['start']} < slow-csv end " \
        "#{slow && (slow['start'] + slow['seconds']).round(3)})", fails)
  # timings.json key stability (consumed by migrate-tableau.rb's stamp gate).
  check(tj12 && (tj12.keys.sort == %w[pool tasks total_seconds]) &&
        tj12['tasks'].all? { |t| (t.keys - %w[task start seconds attempts ok error]).empty? },
        'timings.json keys unchanged (total_seconds/pool/tasks; per-task task/start/seconds/attempts/ok[/error])', fails)

  # (D2) SOLO constraint: images are never concurrent with other images —
  # with 0.3s renders, --all-view-images spans must be strictly serial.
  log13 = File.join(tmp, 'fetch13.log')
  File.write(log13, '')
  code, out = run_discover(script, File.join(tmp, 'out13'), log13, '--all-view-images', images: true,
                           env: { 'STUB_VIEWS' => stub_views, 'STUB_TWB_DASH' => '1',
                                  'STUB_SLOW_PNG' => '0.3' })
  check(code == 0, "--all-view-images run exits 0 (exit #{code})", fails)
  png_fetches = File.readlines(log13).map(&:strip).select { |l| l.start_with?('png ') }
  check(png_fetches.size == 5,
        "all 5 view PNGs fetched once, dashboards/ reuses bytes (got #{png_fetches.size} renders)", fails)
  check(out.include?('reused views/v3.png') && out.include?('reused views/v4.png'),
        'both dashboards/ PNGs reused from the pooled view fetches', fails)
  tj13 = timings(File.join(tmp, 'out13'))
  spans = tj13 ? (tj13['tasks'] || []).select { |t| t['task'].to_s.start_with?('png:', 'dashboard-png:') } : []
  sorted = spans.sort_by { |t| t['start'] }
  overlap = sorted.each_cons(2).find { |a, b| b['start'] < a['start'] + a['seconds'] - 0.05 }
  check(spans.size == 5 && overlap.nil?,
        "image fetches never overlap another image (#{spans.size} spans, overlap: #{overlap ? overlap.map { |t| t['task'] }.inspect : 'none'})", fails)

  # (4) migrate-tableau.rb keeps the --skip-extract-landing live repoint on the
  # skip path. TWO spellings are correct under the opt-in default and both are
  # accepted, so this check survives the coordinated orchestrator flip that
  # restores auto-land (extract-refetch on landing routes):
  #   old: '--no-extract-refetch' if opts[:skip_extract_landing]   (explicit skip)
  #   new: '--extract-refetch' unless opts[:skip_extract_landing]  (landing routes opt in)
  # The backwards combos (refetch ON the live repoint, or opt-out on landing
  # routes only) match neither string and keep failing here.
  wiring = File.read(File.join(DIR, 'migrate-tableau.rb'))
  wired_old = wiring.include?("'--no-extract-refetch' if opts[:skip_extract_landing]")
  wired_new = wiring.include?("'--extract-refetch' unless opts[:skip_extract_landing]")
  check(wired_old || wired_new,
        'orchestrator wires extract-refetch against :skip_extract_landing (either correct spelling)', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
