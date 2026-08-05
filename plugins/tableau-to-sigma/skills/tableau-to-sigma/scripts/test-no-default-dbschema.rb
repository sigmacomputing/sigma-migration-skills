#!/usr/bin/env ruby
# encoding: utf-8
# NO-DEFAULT warehouse db/schema (E2E-caught regression + field gap C1).
#
# WHY: there is no default database. Every org has its own warehouse, and the
# workbook itself usually names it (<connection dbname= schema=> on live
# warehouse connections). A fabricated fallback pair turned "could not derive"
# into a wall of DM-POST 404s on a Virtual-Connection-backed workbook — while
# offline CI stayed green because the fixtures carried the SAME fabricated
# names. This test pins the whole contract:
#
#   Part A (pure Ruby): HydrateCustomSql.twb_dbschema derives [db, schema]
#     pairs from the workbook's own connections, and rejects every connection
#     class whose dbname is NOT a warehouse database (sqlproxy → contentUrl,
#     hyper → file path, virtual-connection → VC name).
#   Part B (source pin): the orchestrator and converter contain NO fabricated
#     db/schema fallback literal — the resolver chain (flags → landing
#     manifest → workbook attributes → hard STOP) is the only path.
#   Part C (node): the converter honors a workbook's own connection
#     dbname/schema when the caller passes no override, and explicit
#     overrides still win.
#
# Offline + deterministic; Part C needs `node` (SKIPs, same convention as
# test-converter-fixtures.rb Part A).
#
# Usage:  ruby scripts/test-no-default-dbschema.rb
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'hydrate-custom-sql'

$fails = 0
def ok(name)
  puts "  ok  #{name}"
end
def fail!(name, detail = nil)
  $fails += 1
  puts "FAIL  #{name}#{detail ? "\n      #{detail}" : ''}"
end
def check(name, cond, detail = nil)
  cond ? ok(name) : fail!(name, detail)
end

HERE = __dir__

def write_twb(dir, name, body)
  path = File.join(dir, name)
  File.write(path, <<~XML)
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook>
      <datasources>
        #{body}
      </datasources>
    </workbook>
  XML
  path
end

Dir.mktmpdir do |dir|
  # --- Part A: twb_dbschema derivation --------------------------------------
  puts '— Part A: HydrateCustomSql.twb_dbschema —'

  fed = write_twb(dir, 'fed.twb', <<~DS)
    <datasource caption='Orders' name='federated.f1'>
      <connection class='federated'>
        <named-connections>
          <named-connection name='snow' caption='snow'>
            <connection class='snowflake' dbname='SRC_DB' schema='SRC_SCH' warehouse='WH' />
          </named-connection>
        </named-connections>
        <relation connection='snow' name='ORDERS' table='[ORDERS]' type='table' />
      </connection>
    </datasource>
  DS
  check('federated snowflake pair derived',
        HydrateCustomSql.twb_dbschema(fed) == [%w[SRC_DB SRC_SCH]],
        HydrateCustomSql.twb_dbschema(fed).inspect)

  proxy = write_twb(dir, 'proxy.twb', <<~DS)
    <datasource caption='Published' name='sqlproxy.p1'>
      <connection class='sqlproxy' dbname='SomePublishedDS' channel='https' />
    </datasource>
  DS
  check('sqlproxy dbname (a contentUrl) never derives',
        HydrateCustomSql.twb_dbschema(proxy) == [],
        HydrateCustomSql.twb_dbschema(proxy).inspect)

  vc = write_twb(dir, 'vc.twb', <<~DS)
    <datasource caption='VC' name='vconn.v1'>
      <connection class='virtual-connection' dbname='MY_VC' schema='MY_VC_SCHEMA' />
    </datasource>
  DS
  check('virtual-connection dbname (the VC name) never derives',
        HydrateCustomSql.twb_dbschema(vc) == [],
        HydrateCustomSql.twb_dbschema(vc).inspect)

  hyper = write_twb(dir, 'hyper.twb', <<~DS)
    <datasource caption='Extract' name='hyper.h1'>
      <connection class='federated'>
        <named-connections>
          <named-connection name='hy'>
            <connection class='hyper' dbname='Data/Extracts/orders.hyper' schema='Extract' />
          </named-connection>
        </named-connections>
      </connection>
    </datasource>
  DS
  check('hyper file-path dbname never derives',
        HydrateCustomSql.twb_dbschema(hyper) == [],
        HydrateCustomSql.twb_dbschema(hyper).inspect)

  mixed = write_twb(dir, 'mixed.twb', <<~DS)
    <datasource caption='Mixed' name='federated.m1'>
      <connection class='federated'>
        <named-connections>
          <named-connection name='hy'>
            <connection class='hyper' dbname='Data/Extracts/x.hyper' schema='Extract' />
          </named-connection>
          <named-connection name='snow'>
            <connection class='snowflake' dbname='REAL_DB' schema='REAL_SCH' />
          </named-connection>
        </named-connections>
      </connection>
    </datasource>
    <datasource caption='Second' name='federated.m2'>
      <connection class='federated'>
        <named-connections>
          <named-connection name='snow2'>
            <connection class='snowflake' dbname='OTHER_DB' schema='OTHER_SCH' />
          </named-connection>
        </named-connections>
      </connection>
    </datasource>
  DS
  check('junk filtered, distinct pairs kept in document order',
        HydrateCustomSql.twb_dbschema(mixed) == [%w[REAL_DB REAL_SCH], %w[OTHER_DB OTHER_SCH]],
        HydrateCustomSql.twb_dbschema(mixed).inspect)

  noschema = write_twb(dir, 'noschema.twb', <<~DS)
    <datasource caption='MySQL' name='mysql.n1'>
      <connection class='mysql' dbname='appdb' server='db.internal' />
    </datasource>
  DS
  check('dbname without schema never derives (no half-pairs)',
        HydrateCustomSql.twb_dbschema(noschema) == [],
        HydrateCustomSql.twb_dbschema(noschema).inspect)

  check('missing file → [] (never raises)',
        HydrateCustomSql.twb_dbschema(File.join(dir, 'absent.twb')) == [])

  # --- Part B: no fabricated fallback literal in the sources ----------------
  puts '— Part B: source pins —'
  orch = File.read(File.join(HERE, 'migrate-tableau.rb'), encoding: 'UTF-8')
  conv = File.read(File.expand_path('../converter/tableau.mjs', HERE), encoding: 'UTF-8')

  fallback_rx = /\|\|\s*['"](?:DEMO_DB|PUBLIC|DEMO)['"]/
  check('orchestrator has NO fabricated db/schema fallback literal',
        orch !~ fallback_rx, orch[fallback_rx].inspect)
  check('converter has NO fabricated db/schema fallback literal',
        conv !~ fallback_rx, conv[fallback_rx].inspect)
  check('orchestrator resolver hard-STOPs when nothing derives',
        orch.include?('cannot determine the warehouse database/schema'))
  check('converter consults the connection pair when no override is passed',
        conv.include?('warehouseDbSchemaFromConn'))

  # --- Part C: converter honors connection attrs; overrides win -------------
  if `which node 2>/dev/null`.strip.empty?
    warn 'SKIP  node not on PATH — converter connection-fallback checks not run (install node to enable)'
  else
    puts '— Part C: converter connection fallback —'
    vendored = File.expand_path('../converter/tableau.mjs', HERE)
    vendored_spec =
      if Gem.win_platform? && vendored.to_s.match?(/\A[A-Za-z]:/)
        'file:///' + vendored.gsub('\\', '/')
      else
        vendored
      end
    conv_twb = write_twb(dir, 'conv.twb', <<~DS)
      <datasource caption='Orders' name='federated.c1'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow' caption='snow'>
              <connection class='snowflake' dbname='SRC_DB' schema='SRC_SCH' warehouse='WH' />
            </named-connection>
          </named-connections>
          <relation connection='snow' name='ORDERS' table='[ORDERS]' type='table'>
            <columns>
              <column datatype='string' name='[REGION]' />
              <column datatype='real' name='[SALES]' />
            </columns>
          </relation>
        </connection>
      </datasource>
    DS
    run_conv = lambda do |twb, opts_js|
      script = <<~JS
        import { convertTableauToSigma } from #{vendored_spec.to_json};
        import { readFileSync } from 'fs';
        const xml = readFileSync(process.argv[1], 'utf8');
        const r = convertTableauToSigma(xml, #{opts_js});
        const els = (r.model?.pages || []).flatMap(p => p.elements || []);
        const wt = els.find(e => e.source && e.source.kind === 'warehouse-table');
        console.log(JSON.stringify(wt ? wt.source.path : null));
      JS
      out, err, st = Open3.capture3('node', '--input-type=module', '-e', script, twb)
      raise "node failed: #{err}" unless st.success?
      JSON.parse(out.lines.last.to_s)
    end

    path_noopt = run_conv.call(conv_twb, '{}')
    check("no override → the workbook's own pair is honored",
          path_noopt == %w[SRC_DB SRC_SCH ORDERS], path_noopt.inspect)

    path_ovr = run_conv.call(conv_twb, '{ database: "OVR_DB", schema: "OVR_SCH" }')
    check('explicit override still wins over connection attrs',
          path_ovr == %w[OVR_DB OVR_SCH ORDERS], path_ovr.inspect)

    vc_twb = write_twb(dir, 'convvc.twb', <<~DS)
      <datasource caption='VC Orders' name='vconn.c2'>
        <connection class='virtual-connection' dbname='MY_VC'>
          <relation name='ORDERS' table='[ORDERS]' type='table'>
            <columns>
              <column datatype='string' name='[REGION]' />
            </columns>
          </relation>
        </connection>
      </datasource>
    DS
    path_vc = run_conv.call(vc_twb, '{}')
    check('virtual-connection name never leaks into the table path',
          !(path_vc || []).include?('MY_VC'), path_vc.inspect)
  end
end

if $fails.zero?
  puts 'PASS  test-no-default-dbschema'
else
  puts "FAIL  test-no-default-dbschema (#{$fails} failing)"
  exit 1
end
