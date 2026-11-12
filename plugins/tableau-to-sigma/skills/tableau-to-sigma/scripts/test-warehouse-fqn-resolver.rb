#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test: db/schema resolution from fully-qualified relation names
# (lib/warehouse_fqn_resolver.rb) — the published-datasource / virtual-connection case.
require 'tmpdir'
require 'fileutils'
require_relative 'lib/warehouse_fqn_resolver'
$fails = 0
def ok(c, m)
  puts "  #{c ? 'PASS' : 'FAIL'}  #{m}"
  $fails += 1 unless c
end
WF = WarehouseFqn

def twb(*tables)
  "<workbook>" + tables.map { |t| "<relation name='X' table='#{t}' type='table'/>" }.join + '</workbook>'
end
def resolve_text(text, csv: nil, default_db: nil, catalog: nil, complete: true, **kw)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.twb'), text)
    if csv
      FileUtils.mkdir_p(File.join(d, 'views'))
      File.write(File.join(d, 'views', 'v.csv'), csv)
    end
    WF.resolve(d, default_db_lookup: default_db ? -> { default_db } : nil,
                  catalog_lookup: catalog ? -> { [catalog, complete] } : nil, **kw)
  end
end

r = resolve_text(twb('[SCHEMA_A].[DIM_A]', '[SCHEMA_A].[DIM_B]'))
ok(r[:status] == :schema_only && r[:schema] == 'SCHEMA_A', "2-part bracketed names → schema only (#{r[:status]})")

r = resolve_text(twb('[SCHEMA_A].[DIM_A]'), default_db: 'DB_X')
ok(r[:status] == :resolved && r[:db] == 'DB_X' && r[:schema] == 'SCHEMA_A', 'schema + Sigma connection default db → resolved')

r = resolve_text(twb('SCHEMA_A.DIM_A'))
ok(r[:status] == :schema_only, 'dotted unbracketed 2-part name parsed')

r = resolve_text(twb('[DB_Q].[SCHEMA_A].[DIM_A]', 'DB_Q.SCHEMA_A.FACT'))
ok(r[:status] == :resolved && r[:db] == 'DB_Q' && r[:schema] == 'SCHEMA_A', '3-part names agree → db + schema')

r = resolve_text(twb('[DB_Q].[SCHEMA_A].[DIM_A]', '[SCHEMA_A].[DIM_B]'))
ok(r[:status] == :resolved && r[:db] == 'DB_Q', '3-part + 2-part naming the same schema agree')

r = resolve_text(twb('[SCHEMA_A].[DIM_A]', '[SCHEMA_B].[DIM_B]'), default_db: 'DB_X')
ok(r[:status] == :ambiguous && r[:candidates].size == 2, 'two schemas → ambiguous, never guessed (even with a default db)')
_c, flag = WF.describe(r)
ok(flag.include?('SCHEMA_A | SCHEMA_B'), "flag line lists the candidates (#{flag})")

r = resolve_text(twb('[DB_Q].[SCHEMA_A].[T1]', '[DB_R].[SCHEMA_A].[T2]'))
ok(r[:status] == :ambiguous, 'two databases → ambiguous')

r = resolve_text(twb('[DIM_A]', 'DIM_B'))
ok(r[:status] == :none, 'unqualified names give no candidates')

r = resolve_text('<workbook><relation table="[S1].[T]" type="table"/><relation type="text">select 1</relation></workbook>')
ok(r[:schema] == 'S1', 'double-quoted attrs + custom-SQL relations ignored')

r = resolve_text('<workbook/>', csv: "Region (DIM_A (SCHEMA_A.DIM_A)),Sales\nEast,1\n", default_db: 'DB_X')
ok(r[:status] == :resolved && r[:schema] == 'SCHEMA_A' && r[:db] == 'DB_X', 'CSV header Region (DIM_A (SCHEMA_A.DIM_A)) surfaces schema')

r = resolve_text(twb('[SCHEMA_A].[DIM_A]'), csv: "Region (DIM_A (SCHEMA_B.DIM_A)),Sales\n")
ok(r[:status] == :ambiguous, 'twb and CSV disagree → ambiguous')

ok(WF.default_database_from({ 'details' => { 'database' => 'DB_Z' } }) == 'DB_Z', 'default db read from connection metadata')
ok(WF.default_database_from({ 'friendlyName' => true }).nil?, 'no default db exposed → nil')

puts 'virtual-connection qualifiers (live-proof shape)'
U1 = 'd2633ac0-4c26-4cc1-b9e7-000000000001'
U2 = 'c91c16a6-66d6-4232-b140-000000000002'
vc_twb = "<workbook><relation connection='publishedConnection.x' name='FACT_A (DB_Q.FACT_A)' table='[#{U1}].[FACT_A (DB_Q.FACT_A)]' type='table'/>" \
         "<relation connection='publishedConnection.x' name='DIM_B (DB_Q.DIM_B)' table='[#{U2}].[DIM_B (DB_Q.DIM_B)]' type='table'/></workbook>"
vc_csv = "State (DIM_B (DB_Q.DIM_B)),Net\nX,1\n"
r = resolve_text(vc_twb, csv: vc_csv)
ok(r[:candidates].none? { |_, sc| sc.to_s.match?(WF::UUID_RE) }, "VC table UUIDs are never read as schemas (#{r[:candidates].inspect})")
refs = Dir.mktmpdir { |d| File.write(File.join(d, 'w.twb'), vc_twb); WF.gather_vc_refs(d) }
ok(refs.map { |x| [x[:qual], x[:table]] } == [[['DB_Q'], 'FACT_A'], [['DB_Q'], 'DIM_B']], "VC qualifiers extracted (#{refs.inspect})")
catalog = [['DB_Q'], ['DB_Q', 'SCH_T'], ['DB_Q', 'SCH_T', 'FACT_A'], ['DB_Q', 'SCH_T', 'DIM_B'],
           ['DB_Q', 'SCH_OTHER', 'FACT_A'], ['DB_OTHER', 'SCH_T', 'FACT_A'], ['DB_OTHER', 'SCH_T', 'DIM_B']]
r = resolve_text(vc_twb, csv: vc_csv, catalog: catalog)
ok(r[:status] == :resolved && r[:db] == 'DB_Q' && r[:schema] == 'SCH_T',
   "2-part VC qualifier is the DATABASE; catalog finds the one schema holding every table (#{r.slice(:status, :db, :schema)})")
ok(r[:source].to_s.include?('catalog'), 'source names the catalog')
r = resolve_text(vc_twb, catalog: [['DB_X', 'DB_Q', 'FACT_A'], ['DB_X', 'DB_Q', 'DIM_B']])
ok(r[:status] == :resolved && r[:db] == 'DB_X' && r[:schema] == 'DB_Q', 'qualifier that is the SCHEMA resolves too')
r = resolve_text(vc_twb, catalog: catalog + [['DB_Q', 'SCH_U', 'FACT_A'], ['DB_Q', 'SCH_U', 'DIM_B']])
_c, flag = WF.describe(r)
ok(r[:status] == :ambiguous && flag.include?('--db DB_Q --schema SCH_T') && flag.include?('--db DB_Q --schema SCH_U'),
   "two schemas hold every table → ambiguous, exact flag choices (#{flag})")
r = resolve_text(vc_twb, catalog: catalog + [['DB_Q', 'SCH_U', 'FACT_A'], ['DB_Q', 'SCH_U', 'DIM_B']], hint_schema: 'SCH_U')
ok(r[:status] == :resolved && r[:schema] == 'SCH_U', 'a lone --schema narrows the catalog match')
r = resolve_text(vc_twb, catalog: [['DB_Q', 'SCH_T', 'FACT_A']])
_c, flag = WF.describe(r)
ok(r[:status] == :vc_unresolved && flag.start_with?('--db DB_Q --schema <SCHEMA holding') && WF.explain(r).include?('database OR the schema'),
   "no pair holds every table → precise stop (#{flag})")
r = resolve_text(vc_twb, catalog: catalog, complete: false)
_c, flag = WF.describe(r)
ok(r[:status] == :vc_unresolved && flag == '--db DB_Q --schema SCH_T', "truncated catalog scan → stop naming the lead (#{flag})")
pages = { nil => { 'entries' => [{ 'path' => %w[A] }], 'hasMore' => true, 'nextPage' => '%7B%22p%22%3A1%7D' },
          '%7B%22p%22%3A1%7D' => { 'entries' => [{ 'path' => %w[A B C] }], 'hasMore' => false } }
seen = []
got, complete = WF.list_catalog_paths('conn-1', lambda { |path|
  seen << path
  pages[path[/page=([^&]+)/, 1]]
})
ok(got == [%w[A], %w[A B C]] && complete && seen.last.include?('page=%7B%22p%22%3A1%7D'), "catalog paging follows nextPage verbatim (#{seen.inspect})")

puts $fails.zero? ? 'ALL PASS' : "#{$fails} FAILED"
exit($fails.zero? ? 0 : 1)
