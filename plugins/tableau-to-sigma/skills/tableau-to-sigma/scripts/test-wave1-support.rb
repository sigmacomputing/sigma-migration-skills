#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-wave1-support.rb — SHARED offline fixture builder for the wave-1
# single-invocation tests (test-wave1-*.rb). Not a test itself: running it
# directly just self-checks the fixture builder and exits 0, so CI globs that
# pick up test-wave1-*.rb stay green.
#
# The fixture drives the REAL orchestrator (migrate-tableau.rb) fully offline:
#   - discovery is stamp-REUSED via the probe-failure path (dummy Tableau env
#     pointing at 127.0.0.1:9 — connection refused, fast) over a pre-built
#     workdir (stamp + get-workbook + .twb + timings + views/*.csv);
#   - the converter never runs: a workdir specs.rb supplies the Specs module
#     (mechanical=false), so no node, no .twb conversion;
#   - Sigma calls fast-fail against 127.0.0.1:9 under allow_fail (reuse scan
#     is skipped via --skip-reuse-scan; column discovery tolerates failure);
#     the parent minting is bypassed via SIGMA_API_TOKEN + SIGMA_TOKEN_MINTED_AT;
#   - the doctor gate is waived (--skip-doctor-gate), creds-free by design.
# No network beyond the refused localhost connects; no credentials read.

require 'json'
require 'time'
require 'fileutils'
require 'open3'
require 'rbconfig'

module Wave1Fixture
  SCRIPTS = __dir__
  ORCH = File.join(SCRIPTS, 'migrate-tableau.rb')

  TWB = <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        <datasource caption='ORDER_FACT (DEMO_DB.ORDER_FACT)' name='federated.fact1'>
          <connection class='federated'>
            <named-connections>
              <named-connection name='snow' caption='snow'><connection class='snowflake' dbname='DEMO_DB' schema='DEMO' /></named-connection>
            </named-connections>
            <relation connection='snow' name='ORDER_FACT' table='[DEMO].[ORDER_FACT]' type='table' />
          </connection>
        </datasource>
      </datasources>
      <worksheets>
        <worksheet name='Alpha Sales'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.fact1'>
                <column caption='Region' name='[Region]' datatype='string' role='dimension' />
                <column caption='Sales' name='[Sales]' datatype='real' role='measure' />
              </datasource-dependencies>
            </view>
            <rows>[federated.fact1].[none:Region:nk]</rows>
            <cols>[federated.fact1].[sum:Sales:qk]</cols>
            <pane><mark class='Bar' /></pane>
          </table>
        </worksheet>
        <worksheet name='Beta Trend'>
          <table>
            <view>
              <datasource-dependencies datasource='federated.fact1'>
                <column caption='Month' name='[Month]' datatype='date' role='dimension' />
                <column caption='Sales' name='[Sales]' datatype='real' role='measure' />
              </datasource-dependencies>
            </view>
            <rows>[federated.fact1].[sum:Sales:qk]</rows>
            <cols>[federated.fact1].[none:Month:nk]</cols>
            <pane><mark class='Line' /></pane>
          </table>
        </worksheet>
      </worksheets>
      <dashboards>
        <dashboard name='Alpha Overview'>
          <zones>
            <zone id='101' name='Alpha Sales' x='0' y='0' w='100000' h='100000' />
          </zones>
        </dashboard>
        <dashboard name='Beta Detail'>
          <zones>
            <zone id='201' name='Beta Trend' x='0' y='0' w='100000' h='100000' />
          </zones>
        </dashboard>
      </dashboards>
    </workbook>
  XML

  SPECS_RB = <<~RUBY
    # Fixture spec generator — keeps the offline run off the converter path.
    module Specs
      def self.dm_spec
        { 'name' => 'Wave1 DM', 'pages' => [{ 'name' => 'Model', 'elements' => [
          { 'name' => 'Order Fact', 'kind' => 'table',
            'source' => { 'kind' => 'warehouse-table', 'path' => %w[DEMO_DB DEMO ORDER_FACT] },
            'columns' => [{ 'name' => 'Region', 'type' => 'text' },
                          { 'name' => 'Sales',  'type' => 'number' }] }
        ] }] }
      end

      def self.wb_spec(_dm_id, _fact_eid)
        { 'pages' => [] }
      end
    end
  RUBY

  # Build a complete stamp-reusable discovery workdir. empty_views: view names
  # whose CSVs are header-only (they trip the empty-CSV question).
  def self.build(dir, empty_views: ['Alpha Sales', 'Beta Trend'], gaps: [], has_extracts: true)
    FileUtils.mkdir_p(File.join(dir, 'views'))
    File.write(File.join(dir, 'workbook-content.twb'), TWB)
    File.write(File.join(dir, 'specs.rb'), SPECS_RB)
    File.write(File.join(dir, 'timings.json'), JSON.generate('total_seconds' => 1, 'pool' => 5, 'tasks' => []))
    File.write(File.join(dir, 'discovery-stamp.json'), JSON.pretty_generate(
                 'workbook_id' => 'wb-fixture', 'updatedAt' => '2026-01-01T00:00:00Z',
                 'stamped_at' => '2026-01-01T00:00:00Z'))
    gw = { 'workbook' => {
      'name' => 'Wave1 Fixture', 'hasExtracts' => has_extracts,
      'views' => { 'view' => [
        { 'name' => 'Alpha Sales',    'contentUrl' => 'Wave1Fixture/sheets/AlphaSales' },
        { 'name' => 'Beta Trend',     'contentUrl' => 'Wave1Fixture/sheets/BetaTrend' },
        { 'name' => 'Alpha Overview', 'contentUrl' => 'Wave1Fixture/sheets/AlphaOverview' },
        { 'name' => 'Beta Detail',    'contentUrl' => 'Wave1Fixture/sheets/BetaDetail' }
      ] } } }
    File.write(File.join(dir, 'get-workbook.json'), JSON.pretty_generate(gw))
    ['Alpha Sales', 'Beta Trend'].each do |v|
      rows = empty_views.include?(v) ? "Region,Sales\n" : "Region,Sales\nEast,10\nWest,20\n"
      File.write(File.join(dir, 'views', "#{v}.csv"), rows)
    end
    File.write(File.join(dir, 'wave1-fixture-gaps-report.json'),
               JSON.pretty_generate('detected_features' => gaps))
    File.write(File.join(dir, 'wave1-fixture-gaps-report.md'), "# fixture gap report\n")
    dir
  end

  def self.verified_png_read(dir)
    File.write(File.join(dir, 'png-read.json'), JSON.pretty_generate(
                 'source_png' => 'views/alpha.png',
                 'tiles' => [
                   { 'title' => 'Alpha Sales', 'kind' => 'bar-chart', 'orientation' => 'vertical' },
                   { 'title' => 'Beta Trend', 'kind' => 'line-chart' }
                 ],
                 'text_elements' => [], 'filter_shelf' => []))
  end

  # Offline env: dummy tokens (no minting), refused-localhost endpoints (fast
  # fail), UTF-8 locale. png_wait short-circuits the wait-gate by default so
  # tests that are not about the gate never sit in it.
  #
  # CREDS-FREE BY CONSTRUCTION: TABLEAU_PAT_SECRET is set to a dummy so
  # tableau_rest.rb NEVER auto-loads a developer's real ~/.sigma-migration/env,
  # and TABLEAU_PAT_NAME is explicitly UNSET (nil) so refresh_token! raises
  # AuthError instantly (no network) and the orchestrator falls back to the
  # dummy TABLEAU_AUTH_TOKEN — a live PAT signin from a test would count
  # toward Tableau's 4-strike PAT lockout.
  def self.env(png_wait: '1')
    {
      'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8',
      # Hermetic to branch drift: fixture runs exercise the REAL orchestrator,
      # whose staleness gate compares the checkout against origin/main — any
      # in-review branch is legitimately "behind" while main moves (the gate's
      # job is to protect FIELD runs, not test fixtures). Without this, every
      # PR goes red the moment main advances (observed live on CI).
      'SIGMA_SKIP_VERSION_CHECK' => '1',
      'SIGMA_API_TOKEN' => 'dummy-token',
      'SIGMA_TOKEN_MINTED_AT' => Time.now.utc.iso8601,
      # Non-nil dummies: sigma_rest.rb autoloads the WHOLE neutral cred file
      # (~/.sigma-migration/env — including a developer's real TABLEAU_PAT_*)
      # when SIGMA_CLIENT_ID is nil. Dummy values keep the autoload off.
      'SIGMA_CLIENT_ID' => 'dummy-client-id', 'SIGMA_CLIENT_SECRET' => 'dummy-client-secret',
      'SIGMA_BASE_URL' => 'http://127.0.0.1:9',
      'TABLEAU_AUTH_TOKEN' => 'dummy-tab-token',
      'TABLEAU_SERVER_URL' => 'http://127.0.0.1:9',
      'TABLEAU_SITE_ID' => 'site-x',
      'TABLEAU_PAT_NAME' => nil,
      'TABLEAU_PAT_SECRET' => 'dummy-pat-secret-not-a-credential',
      'TABLEAU_SITE_CONTENT_URL' => 'dummy-site',
      'SIGMA_PNG_READ_TIMEOUT_S' => png_wait,
      'SIGMA_SKIP_CRED_SMOKE' => 'offline test'
    }
  end

  BASE_ARGS = ['--workbook', 'Wave1 Fixture', '--connection', 'conn-x',
               '--skip-doctor-gate', 'offline wave1 test', '--skip-reuse-scan'].freeze

  # Run the orchestrator against the fixture. Returns [stdout+stderr, status].
  def self.run(dir, extra_args = [], env_over = {}, png_wait: '1')
    cmd = [RbConfig.ruby, ORCH, *BASE_ARGS, '--out', dir, *extra_args]
    # Hermetic HOME: the real ~/.sigma-migration carries a cached doctor.json
    # whose behind_count reflects branch-vs-main drift — the stale gate then
    # fails every in-review branch the moment main moves (observed on CI and
    # locally). An isolated HOME has no cached report (stale gate skips by its
    # own best-effort contract) and gets a minimal passing bootstrap sentinel
    # so intake's exit-6 gate opens the same way it does on a bootstrapped
    # machine. Fixtures must be immune to machine state and branch drift.
    Open3.capture2e(hermetic_env(dir, png_wait: png_wait).merge(env_over), *cmd)
  end

  # The full fixture environment incl. HOME isolation — EVERY orchestrator
  # spawn in the wave-1 tests must use this (directly or via run); a bare
  # env() call leaks the parent HOME and re-couples the test to machine state.
  def self.hermetic_env(dir, png_wait: '1')
    home = File.join(dir, '.home')
    sm = File.join(home, '.sigma-migration')
    FileUtils.mkdir_p(sm)
    sentinel = File.join(sm, 'bootstrap.json')
    unless File.exist?(sentinel)
      File.write(sentinel, JSON.generate(
                   'doctor_pass' => true, 'mode' => 'full', 'actions' => [],
                   'completed_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
    end
    env(png_wait: png_wait).merge('HOME' => home, 'USERPROFILE' => home)
  end
end

if __FILE__ == $PROGRAM_NAME
  require 'tmpdir'
  Dir.mktmpdir do |d|
    Wave1Fixture.build(d)
    ok = File.exist?(File.join(d, 'workbook-content.twb')) &&
         File.exist?(File.join(d, 'specs.rb'))
    puts "  #{ok ? 'PASS' : 'FAIL'}  wave1 fixture builder self-check"
    exit(ok ? 0 : 1)
  end
end
