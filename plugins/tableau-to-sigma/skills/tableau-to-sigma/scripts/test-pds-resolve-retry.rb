#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the PDS-resolver 401 retry asymmetry (issue #422).
#
# resolve-published-ds.rb makes two Tableau calls per published data source —
# find_datasource_by_content_url (the PDS lookup) and download_datasource_content
# (the content download). They USED to run with ONLY lib/tableau_rest.rb#request's
# single inline 401-refresh, unlike the discovery path (tableau-discover.rb#run_task)
# which additionally re-mints on a 401 that escapes the lib retry. So a single
# transient signin-race 401 on the resolve path had no cushion, and — because a
# dropped PDS is (correctly) treated as "abort rather than fabricate a phantom
# relation" — it took the whole migration down. The rescued error was also
# truncated to `e.message.lines.first`, dropping the HTTP body, so a real 403
# "no Download capability" looked identical to a transient 401 in the log.
#
# The fix: with_remint_on_401 gives both calls the discovery-path re-mint budget,
# and tableau_error_detail logs a generous excerpt (status + body), not line 1.
#
# Proven with a STUBBED Tableau lib (the script + its real hydrate/zip libs are
# copied to a tmpdir whose lib/ carries a stub tableau_rest.rb, so no network is
# possible). Each scenario is driven by ENV read by the stub. Offline.
#
# Usage: ruby scripts/test-pds-resolve-retry.rb

require 'json'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

DIR = __dir__
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Stub Tableau REST: no network. Behaviour is selected by ENV['STUB_SCENARIO'];
# every re-mint is appended to STUB_LOG so the test can assert the outer 401
# budget actually fired. Classic method defs — the skills target Ruby 2.6.
STUB = <<~'RUBY'
  require 'json'
  module Tableau
    class Error < StandardError; end
    @lookup_calls = 0
    @download_calls = 0
    @remints = 0

    def self.rec_remint
      @remints += 1
      File.open(ENV.fetch('STUB_LOG'), 'a') { |f| f.puts("REMINT #{@remints}") }
    end

    # A realistic lib-shaped error: status line THEN response body on later lines,
    # exactly like lib/tableau_rest.rb#request builds ("METHOD path -> CODE msg\nbody").
    def self.err(code, msg, body)
      Error.new("GET /api/3.22/sites/s/datasources -> #{code} #{msg}\n#{body}")
    end

    def self.find_datasource_by_content_url(content_url)
      @lookup_calls += 1
      case ENV['STUB_SCENARIO']
      when 'lookup_401_then_ok'
        raise err(401, 'Unauthorized', '<error><summary>Signin race</summary></error>') if @lookup_calls == 1
      end
      { 'id' => 'ds-luid-1', 'name' => 'PubOrders' }
    end

    def self.download_datasource_content(_id, include_extract: false)
      @download_calls += 1
      case ENV['STUB_SCENARIO']
      when 'download_401_then_ok'
        raise err(401, 'Unauthorized', '<error><summary>Session not live yet</summary></error>') if @download_calls == 1
      when 'download_403_persistent'
        raise err(403, 'Forbidden',
                  '<error><summary>User does not have the Download capability on this datasource</summary></error>')
      when 'download_401_exhaust'
        raise err(401, 'Unauthorized', '<error><summary>persistent signin failure</summary></error>')
      when 'download_select_star_databricks'
        # #453/#454: a Databricks PDS whose Custom SQL is a bare `SELECT * FROM
        # <lowercase table>`. parse can't enumerate `*`, but the table IS resolvable.
        return <<~TDS
          <datasource>
            <connection class='databricks' dbname='analytics_db' schema='reporting'>
              <relation type='text' name='Custom SQL Query'>SELECT * FROM analytics_db.reporting.account_facts</relation>
            </connection>
          </datasource>
        TDS
      when 'download_unresolvable_star'
        # A genuinely-unresolvable Custom SQL (multi-table join under SELECT *) —
        # expansion would change semantics, so it stays 0-column text → hard abort.
        return <<~TDS
          <datasource>
            <connection class='databricks' dbname='analytics_db' schema='reporting'>
              <relation type='text' name='Custom SQL Query'>SELECT * FROM reporting.a JOIN reporting.b ON a.id = b.id</relation>
            </connection>
          </datasource>
        TDS
      end
      # bare .tds (no zip) with a real table relation → a valid descriptor.
      <<~TDS
        <datasource>
          <connection class='snowflake' dbname='ANALYTICS' schema='PUBLIC'>
            <relation type='table' table='[PUBLIC].[ORDERS]' name='ORDERS'/>
          </connection>
        </datasource>
      TDS
    end

    def self.refresh_token!
      rec_remint
      'new-token'
    end
  end
RUBY

# A minimal .twb: ONE datasource on a sqlproxy connection with no real relation
# and a dbname (== the PDS contentUrl) — exactly what resolve-published-ds.rb
# treats as a published-DS placeholder to resolve.
TWB = <<~'XML'
  <?xml version='1.0' encoding='utf-8'?>
  <workbook>
    <datasources>
      <datasource caption='Published Orders' name='federated.pub'>
        <connection class='sqlproxy' dbname='pub_orders_contenturl'>
          <relation type='table' table='[sqlproxy]' name='sqlproxy'/>
        </connection>
      </datasource>
    </datasources>
  </workbook>
XML

def run_resolve(script, scenario, twb_path, out_path, log_path)
  env = { 'STUB_SCENARIO' => scenario, 'STUB_LOG' => log_path }
  cmd = [RbConfig.ruby, script, '--twb', twb_path, '--out', out_path]
  out = IO.popen(env, cmd, err: %i[child out], &:read)
  [$?.exitstatus, out]
end

Dir.mktmpdir do |tmp|
  FileUtils.mkdir_p(File.join(tmp, 'lib'))
  script = File.join(tmp, 'resolve-published-ds.rb')
  FileUtils.cp(File.join(DIR, 'resolve-published-ds.rb'), script)
  # Real libs the script require_relatives; the stub REPLACES tableau_rest.rb.
  FileUtils.cp(File.join(DIR, 'hydrate-custom-sql.rb'), File.join(tmp, 'hydrate-custom-sql.rb'))
  FileUtils.cp(File.join(DIR, 'lib', 'zip_extract.rb'), File.join(tmp, 'lib', 'zip_extract.rb'))
  File.write(File.join(tmp, 'lib', 'tableau_rest.rb'), STUB)
  twb = File.join(tmp, 'workbook-content.twb')
  File.write(twb, TWB)

  run = lambda do |scenario|
    out_path = File.join(tmp, "#{scenario}.json")
    log_path = File.join(tmp, "#{scenario}.log")
    File.write(log_path, '')
    code, out = run_resolve(script, scenario, twb, out_path, log_path)
    descriptors = File.exist?(out_path) ? JSON.parse(File.read(out_path)) : nil
    remints = File.exist?(log_path) ? File.readlines(log_path).count { |l| l.start_with?('REMINT') } : 0
    { code: code, out: out, descriptors: descriptors, remints: remints }
  end

  # (a1) lookup 401-then-success: re-mint on the PDS-lookup call → resolve succeeds.
  r = run.call('lookup_401_then_ok')
  check(r[:code] == 0, "(a1) lookup 401→ok: completes (exit #{r[:code]})", fails)
  check(r[:descriptors]&.size == 1, "(a1) lookup 401→ok: PDS resolved (no abort), got #{r[:descriptors]&.size.inspect}", fails)
  check(r[:remints] == 1, "(a1) lookup 401→ok: exactly one re-mint fired (got #{r[:remints]})", fails)
  check(r[:out].include?('re-minting token'), '(a1) lookup 401→ok: re-mint is logged', fails)

  # (a2) download 401-then-success: re-mint on the content-download call → resolve succeeds.
  r = run.call('download_401_then_ok')
  check(r[:code] == 0, "(a2) download 401→ok: completes (exit #{r[:code]})", fails)
  check(r[:descriptors]&.size == 1, "(a2) download 401→ok: PDS resolved (no abort), got #{r[:descriptors]&.size.inspect}", fails)
  check(r[:descriptors]&.first&.dig('table') == '[PUBLIC].[ORDERS]', '(a2) download 401→ok: descriptor carries the real relation', fails)
  check(r[:remints] == 1, "(a2) download 401→ok: exactly one re-mint fired (got #{r[:remints]})", fails)

  # (b) persistent 403 (no Download capability): still aborts (descriptor DROPPED,
  #     never fabricated), and the FULL error — status AND body — is surfaced.
  r = run.call('download_403_persistent')
  check(r[:code] == 0, "(b) 403: script completes cleanly (exit #{r[:code]})", fails)
  check(r[:descriptors] == [], "(b) 403: descriptor DROPPED not fabricated (got #{r[:descriptors].inspect})", fails)
  check(r[:remints].zero?, "(b) 403: a non-401 is NOT re-minted (got #{r[:remints]} re-mints)", fails)
  check(r[:out].include?('403'), '(b) 403: HTTP status present in the log', fails)
  check(r[:out].include?('Download capability'),
        '(b) 403: response BODY surfaced (full error, not just line 1)', fails)

  # (c) 401 exhausting the budget: still aborts loudly — descriptor DROPPED, and
  #     the 401 is surfaced after the re-mint budget is spent.
  r = run.call('download_401_exhaust')
  check(r[:code] == 0, "(c) 401-exhaust: script completes cleanly (exit #{r[:code]})", fails)
  check(r[:descriptors] == [], "(c) 401-exhaust: descriptor DROPPED not fabricated (got #{r[:descriptors].inspect})", fails)
  check(r[:remints] >= 2, "(c) 401-exhaust: re-mint budget was exercised (got #{r[:remints]} re-mints)", fails)
  check(r[:out].include?('401') && r[:out].include?('content download failed'),
        '(c) 401-exhaust: the exhausted 401 is surfaced loudly', fails)

  # (d) bare `SELECT * FROM <table>` (Databricks): resolves — NO abort — to the
  #     TABLE (expanded), with the lowercase table PRESERVED and the warehouse
  #     class captured from the PDS metadata (#453 + #454).
  r = run.call('download_select_star_databricks')
  d = r[:descriptors]&.first
  check(r[:code] == 0, "(d) select*: script completes (exit #{r[:code]})", fails)
  check(r[:descriptors]&.size == 1, "(d) select*: PDS resolved (no abort), got #{r[:descriptors]&.size.inspect}", fails)
  check(d && d['relationType'] == 'table', "(d) select*: bare SELECT* EXPANDED to a table relation (#453), got #{d && d['relationType']}", fails)
  check(d && d['table'] == 'analytics_db.reporting.account_facts',
        "(d) select*: table extracted, lowercase PRESERVED, got #{d && d['table'].inspect}", fails)
  check(d && d['warehouseClass'] == 'databricks', "(d) select*: warehouse class captured from PDS metadata (#454), got #{d && d['warehouseClass'].inspect}", fails)
  check(r[:out].include?('table analytics_db.reporting.account_facts'),
        '(d) select*: resolution logged as a table (not an empty Custom SQL)', fails)

  # (e) genuinely-unresolvable `SELECT *` (multi-table JOIN): NOT expanded — stays
  #     a 0-column Custom SQL descriptor, so hydration refuses it and migrate
  #     hard-aborts loudly (never fabricated into a phantom table).
  r = run.call('download_unresolvable_star')
  d = r[:descriptors]&.first
  check(d && d['relationType'] == 'text', "(e) unresolvable star: kept as Custom SQL (not expanded), got #{d && d['relationType']}", fails)
  check(d && (d['columns'] || []).empty?, "(e) unresolvable star: 0 columns → hydration refuses → hard abort preserved, got #{d && d['columns'].inspect}", fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
