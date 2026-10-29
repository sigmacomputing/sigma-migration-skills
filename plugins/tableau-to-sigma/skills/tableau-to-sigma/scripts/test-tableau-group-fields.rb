#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test: Tableau GROUP fields (<calculation class='categorical-bin'>) convert to a Sigma
# calculated column that every consumer can resolve.
#
# A group is a datasource column such as
#   <column caption='Officer Name (group)' name='[Officer Name (group)]' ...>
#     <calculation class='categorical-bin' column='[OFFICER_NAME]' new-bin='true'>
#       <bin value='"Team North"'><value>"Alice"</value><value>"Bob"</value></bin>
#       <bin default-name='true' value='"Carol"'><value>"Carol"</value></bin>
#     </calculation>
#   </column>
# (schema: twb_2026.2.0.xsd DataSource-Calculation-G / DataSource-Bins-G). Nothing handled it: the
# vendored converter skipped every "(group)" field, so (a) a calc over the group lost it — or, worse,
# the caption<->alias reconciliation silently re-pointed [Officer Name (group)] at the UNGROUPED
# [Officer Name], so "IF [group] = 'Team North'" never matched — and (b) a group on Rows or in a
# categorical filter had no master column to land on.
#
# Fix under test (converter/tableau.mjs, local patch recorded in converter/PROVENANCE.json): the group
# becomes a named calculated column on the fact element, Switch([Src], member, bucket, ..., else),
# else = the member itself (unlisted members keep their value) or the "Other" bucket. Being a normal
# DM column it flows through derive_master into the master map, so calcs, shelves and filters resolve.
#
# Part 1  converter output on fixtures/group-fields.twb (needs `node`; SKIPs without it)
# Part 2  more member shapes: numeric source, %null% member, quotes/backslashes, an unreferenced group
# Part 3  converter -> derive_master -> build-charts: the group on Rows and as a categorical filter
#
# Usage:  ruby scripts/test-tableau-group-fields.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/ruby_compat'
require_relative 'mechanical-specs'

DIR       = __dir__
PARSER    = File.join(DIR, 'parse-twb-layout.rb')
BUILD     = File.join(DIR, 'build-charts-from-signals.rb')
FIXTURE   = File.join(DIR, 'fixtures', 'group-fields.twb')
VENDORED  = File.expand_path('../converter/tableau.mjs', __dir__)
RUBY      = RbConfig.ruby
# Node ESM on Windows rejects a bare drive-letter specifier — file:// URL there (same idiom as
# test-param-member-aliases.rb / mechanical-specs.rb run_converter).
VENDORED_SPEC =
  if Gem.win_platform? && VENDORED.to_s.match?(/\A[A-Za-z]:/)
    'file:///' + VENDORED.gsub('\\', '/')
  else
    VENDORED
  end

if `which node 2>/dev/null`.strip.empty?
  warn 'SKIP  node not on PATH — group-field fixtures not run (install node to enable)'
  exit 0
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Run the vendored converter over one .twb text; returns the parsed result hash.
def convert(twb_text)
  Dir.mktmpdir do |dir|
    twb = File.join(dir, 'wb.twb')
    File.write(twb, twb_text)
    drive = File.join(dir, 'drive.mjs')
    File.write(drive, <<~MJS)
      import { convertTableauToSigma } from #{VENDORED_SPEC.to_json};
      import { readFileSync } from 'fs';
      const xml = readFileSync(#{twb.to_json}, 'utf8');
      console.log(JSON.stringify(convertTableauToSigma(xml, { connectionId: 'CONN' })));
    MJS
    out, err, st = Open3.capture3('node', drive)
    abort "node driver failed: #{err}" unless st.success?
    JSON.parse(out)
  end
end

def fact_columns(res)
  els = (res.dig('model', 'pages') || []).flat_map { |p| p['elements'] || [] }
  tbl = els.find { |e| e['kind'] == 'table' && e.dig('source', 'kind') == 'warehouse-table' }
  (tbl || {})['columns'] || []
end

FIXTURE_TEXT = File.read(FIXTURE, encoding: 'utf-8')
res = convert(FIXTURE_TEXT)
cols = fact_columns(res)
formula_of = ->(name) { cols.find { |c| c['name'] == name }&.fetch('formula') }
warnings = res['warnings'] || []

puts 'Part 1 - converter: a group becomes a Switch calculated column'
check(formula_of.call('Officer Name (group)') == 'Switch([Officer Name], "Alice", "Team North", "Bob", "Team North", [Officer Name])',
      "explicit bins -> Switch member/bucket pairs; the default-name bin passes through; unlisted members keep their own value (got #{formula_of.call('Officer Name (group)').inspect})", fails)
check(formula_of.call('Region (group)') == 'Switch([Region], "CA", "West Coast", "OR", "West Coast", "Other")',
      "an others='true' bucket is the else branch (got #{formula_of.call('Region (group)').inspect})", fails)
check(formula_of.call('Region Tier (group)') == 'Switch([Region], "CA", "Core", "NY", "Core", "Other")',
      "the calculation's default='\"Other\"' spelling of the catch-all is honored (got #{formula_of.call('Region Tier (group)').inspect})", fails)
check(warnings.any? { |w| w.include?('Group "Officer Name (group)"') && w.start_with?("✅") },
      'the group conversion is announced as a success warning', fails)

puts 'Part 1b - calcs over a group keep the GROUP (never the ungrouped column) and are not dropped'
dropped = warnings.grep(/Dropped calc/)
check(formula_of.call('North Flag') == 'If([Officer Name (group)] = "Team North", "Yes", "No")' && dropped.empty?,
      "IF over the group -> If([Officer Name (group)] = ...), not dropped and not re-pointed at [Officer Name] (got #{formula_of.call('North Flag').inspect}; dropped: #{dropped.inspect})", fails)
check(formula_of.call('Name Has Ali') == 'Contains(Upper([Officer Name (group)]), "ALI")' && dropped.empty?,
      "row-level CONTAINS(UPPER(group), ...) -> a DM column over the group (got #{formula_of.call('Name Has Ali').inspect})", fails)
search = (res['workbookPatterns'] || []).find { |pat| pat['name'] == 'Name Search' }
check(search && search['kind'] == 'param-filter' && search['source'].include?('[Officer Name (group)]') &&
      cols.any? { |c| c['name'] == 'Officer Name (group)' },
      'the CONTAINS(LOOKUP(MAX(UPPER([group])),0), UPPER([Parameters].[P])) search calc reaches the workbook layer naming a group that exists as a DM column', fails)

puts
puts 'Part 2 - member shapes'
def one_group_twb(datatype:, src_datatype:, bins:, extra_calc_attrs: '', src_col: 'GRP_SRC')
  <<~XML
    <?xml version='1.0' encoding='utf-8' ?>
    <workbook version='18.1' xmlns:user='http://www.tableausoftware.com/xml/user'>
      <datasources>
        <datasource caption='T' inline='true' name='federated.g0002' version='18.1'>
          <connection class='federated'>
            <named-connections>
              <named-connection caption='wh' name='snowflake.g0002'>
                <connection class='snowflake' dbname='SALESDB' schema='DEMO' server='warehouse.example.com' />
              </named-connection>
            </named-connections>
            <relation connection='snowflake.g0002' name='GRP_T' table='[DEMO].[GRP_T]' type='table' />
          </connection>
          <column caption='Src' datatype='#{src_datatype}' name='[#{src_col}]' role='dimension' type='nominal' />
          <column caption='Amount' datatype='real' name='[AMOUNT]' role='measure' type='quantitative' />
          <column caption='Src (group)' datatype='#{datatype}' name='[Src (group)]' role='dimension' type='nominal'>
            <calculation class='categorical-bin' column='[#{src_col}]' #{extra_calc_attrs} new-bin='true'>
              #{bins}
            </calculation>
          </column>
        </datasource>
      </datasources>
    </workbook>
  XML
end

num = convert(one_group_twb(datatype: 'string', src_datatype: 'integer',
                            bins: "<bin value='&quot;Low&quot;'><value>1</value><value>2</value></bin>" \
                                  "<bin value='&quot;High&quot;'><value>9</value></bin>"))
nf = fact_columns(num).find { |c| c['name'] == 'Src (group)' }&.fetch('formula')
check(nf == 'Switch([Src], 1, "Low", 2, "Low", 9, "High", Text([Src]))',
      "numeric source: unquoted members stay numbers; the passthrough is Text([Src]) so the column stays one type (got #{nf.inspect})", fails)

nul = convert(one_group_twb(datatype: 'string', src_datatype: 'string',
                            bins: "<bin value='&quot;Unassigned&quot;'><value>%null%</value></bin>" \
                                  "<bin value='&quot;Big&quot;'><value>&quot;A&quot;</value></bin>"))
nl = fact_columns(nul).find { |c| c['name'] == 'Src (group)' }&.fetch('formula')
check(nl == 'If(IsNull([Src]), "Unassigned", Switch([Src], "A", "Big", [Src]))',
      "a %null% member maps through IsNull (Switch never matches a null) (got #{nl.inspect})", fails)

esc = convert(one_group_twb(datatype: 'string', src_datatype: 'string',
                            bins: "<bin value='&quot;Say \\&quot;hi\\&quot;&quot;'><value>&quot;a\\b&quot;</value></bin>"))
ef = fact_columns(esc).find { |c| c['name'] == 'Src (group)' }&.fetch('formula')
check(ef == 'Switch([Src], "a\\\\b", "Say \\"hi\\"", [Src])',
      "backslashes and embedded quotes are escaped into valid Sigma string literals (got #{ef.inspect})", fails)

dup = convert(one_group_twb(datatype: 'string', src_datatype: 'string',
                            bins: "<bin value='&quot;X&quot;'><value>&quot;A&quot;</value></bin>" \
                                  "<bin value='&quot;Y&quot;'><value>&quot;A&quot;</value><value>&quot;B&quot;</value></bin>"))
df = fact_columns(dup).find { |c| c['name'] == 'Src (group)' }&.fetch('formula')
check(df == 'Switch([Src], "A", "X", "B", "Y", [Src])',
      "a member listed in two bins keeps its FIRST bucket, one Switch case (got #{df.inspect})", fails)

unref = convert(one_group_twb(datatype: 'string', src_datatype: 'string', src_col: 'MISSING_COL',
                              bins: "<bin value='&quot;X&quot;'><value>&quot;A&quot;</value></bin>")
                  .sub("<column caption='Src' datatype='string' name='[MISSING_COL]' role='dimension' type='nominal' />\n", ''))
check(fact_columns(unref).none? { |c| c['name'] == 'Src (group)' } &&
      (unref['warnings'] || []).any? { |w| w.include?('Dropped calc "Src (group)"') },
      'a group whose source column does not exist is dropped LOUDLY (named warning), not emitted dangling', fails)

puts
puts 'Part 3 - converter -> derive_master -> build-charts: the group on Rows and as a categorical filter'
conv = JSON.parse(JSON.dump(res))
model = conv['model']
MechanicalSpecs.fixup_dm_spec(model)
fact = MechanicalSpecs.pick_fact(model)
base = MechanicalSpecs.base_of(model, fact)
derived = MechanicalSpecs.derive_master(fact, fact['name'], base, nil, model)
mmap = derived['mmap']
mcols = derived['master_columns']
check(%w[Officer\ Name\ (group) Region\ (group) Region\ Tier\ (group)].all? { |n| mcols.any? { |m| m['name'] == n } },
      "all three groups are master columns (got #{mcols.map { |m| m['name'] }.inspect})", fails)
check(mcols.find { |m| m['name'] == 'Officer Name (group)' }&.fetch('formula') == '[Officer Activity/Officer Name (group)]',
      'the group master column reads the DM group column', fails)

# One parse + one build (the harness mirrors test-stress-gaps.rb / test-calc-paren-field-names.rb).
def run_pipeline(twb_text, csvs:, mmap:)
  Dir.mktmpdir do |d|
    twb = File.join(d, 'wb.twb')
    File.write(twb, twb_text)
    lay = File.join(d, 'dashboard-layout.json')
    o, = Open3.capture2e(RUBY, PARSER, twb, lay)
    return { ok: false, log: o } unless File.exist?(lay)
    views = csvs.each_with_index.map { |(name, _), i| { 'id' => "v#{i}", 'name' => name } }
    Dir.mkdir(File.join(d, 'views'))
    csvs.each_with_index { |(_, body), i| File.write(File.join(d, 'views', "v#{i}.csv"), body) }
    File.write(File.join(d, 'get-workbook.json'),
               JSON.dump('workbook' => { 'name' => 'GF', 'hasExtracts' => false }, 'views' => { 'view' => views }))
    File.write(File.join(d, 'master-columns.json'), JSON.dump(mmap))
    out = File.join(d, 'chart-specs.json')
    log, st = Open3.capture2e(RUBY, BUILD, '--tableau-dir', d, '--layout', lay,
                              '--meta', File.join(d, 'dashboard-layout-meta.json'),
                              '--master-map', File.join(d, 'master-columns.json'),
                              '--master-element-id', 'master', '--auto-controls',
                              '--skip-dashboard-read', 'offline test fixture', '--out', out)
    specs = File.exist?(out) ? JSON.parse(File.read(out)) : nil
    flat = specs.is_a?(Hash) ? specs['pages'].flat_map { |pg| pg['elements'] } : (specs || [])
    { ok: st.success?, log: log, specs: specs, elements: flat,
      coverage: (f = File.join(d, 'coverage.json')) && File.exist?(f) ? JSON.parse(File.read(f)) : nil }
  end
end

csvs = {
  'Volume by Team' => "Officer Name (group),Volume\nTeam North,1600\nCarol,400\n",
  'Volume by Region' => "Region (group),Volume\nWest Coast,900\nOther,300\n"
}
run = run_pipeline(FIXTURE_TEXT, csvs: csvs, mmap: mmap)
puts run[:log] if ENV['DEBUG_LOG']
check(run[:ok], "build-charts exits 0 (got: #{run[:log].to_s.lines.grep(/Error/).first(2).inspect})", fails)

team = (run[:elements] || []).find { |e| e['id'] == 'el-volume-by-team' }
region = (run[:elements] || []).find { |e| e['id'] == 'el-volume-by-region' }
check(!team.nil? && !region.nil?, 'both group charts are built', fails)
tfs = ((team || {})['columns'] || []).map { |c| c['formula'].to_s }
rfs = ((region || {})['columns'] || []).map { |c| c['formula'].to_s }
# A [Master/<name>] ref only counts when <name> is a real master column (the builder will happily
# write [Master/<raw header>] for a header nothing matched — that ref then dangles at POST time).
resolves = lambda do |formulas|
  names = formulas.flat_map { |f| f.scan(%r{\[Master/([^\]]+)\]}).flatten }
  !names.empty? && names.all? { |n| mcols.any? { |m| m['name'] == n } }
end
check(tfs.include?('[Master/Officer Name (group)]') && !tfs.include?('[Master/Officer Name]') && resolves.call(tfs),
      "the group on Rows is the category column [Master/Officer Name (group)] (never the UNGROUPED [Master/Officer Name]) and it RESOLVES to a master column (columns: #{tfs.inspect})", fails)
check(rfs.include?('[Master/Region (group)]') && resolves.call(rfs),
      "the Other-bucket group on Rows is [Master/Region (group)] and it RESOLVES (columns: #{rfs.inspect})", fails)
unmatched = run[:log].to_s.lines.grep(/group/i).grep(/ZONE DROPPED|could not be resolved|no master column|skipped/i)
check(unmatched.empty?,
      "no 'no master column matched / could not be resolved / skipped / ZONE DROPPED' warning mentions a group (got #{unmatched.first(3).inspect})", fails)

# The categorical filter on the group: a list filter keyed on the group's chart column, members preserved.
tfilters = (team || {})['filters'] || []
gid = ((team || {})['columns'] || []).find { |c| c['formula'] == '[Master/Officer Name (group)]' }&.fetch('id', nil)
gf = tfilters.find { |f| f['columnId'] == gid }
check(gid && resolves.call(['[Master/Officer Name (group)]']) && gf && gf['kind'] == 'list' &&
      Array(gf['values']).map(&:to_s).sort == ['Carol', 'Team North'],
      "the group categorical filter is a list filter on the RESOLVED group column with members Team North + Carol (filters: #{tfilters.inspect[0, 240]})", fails)

puts
if fails.empty?
  puts 'test-tableau-group-fields: ALL PASS'
else
  puts "test-tableau-group-fields: #{fails.size} FAIL"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
