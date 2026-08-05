#!/usr/bin/env ruby
# test-deterministic-ids-kpi-format.rb — two guards on build-workbook-from-quicksight.rb:
#
# ISSUE #541 — element/column ids must be DETERMINISTIC. They used to be
# SecureRandom, so every build minted a fresh id space for the same analysis. A
# spec PUT to an existing workbook then referenced elements the already-applied
# layout.xml and control-scope.json knew by their OLD ids: control lint reported
# ghost `mustReach` targets (32, live) and a layout pointing at elements absent
# from the spec renders the page N/A / blank (the Arine RCA class).
#
# ISSUE #542 — QuickSight often ships NO FormatConfiguration while still RENDERING
# its KPI big-numbers comma-grouped ("15,045,294.83"). Unformatted, Sigma renders
# them period-grouped ("15.045.294.83"), which reads as broken. KPI measures get a
# grouped D3 default; the decimal choice comes from the AGGREGATION, never the
# column name; chart data labels stay untouched (they already match QuickSight's
# abbreviated 3.9M form).
#
# Offline + creds-free: the builder reads JSON and writes JSON, no API.
# Run: ruby scripts/test-deterministic-ids-kpi-format.rb
require 'json'
require 'tmpdir'
require 'open3'

$fail = 0
def ok(desc); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{desc}"; $fail += 1 unless r; end

BUILDER = File.expand_path('build-workbook-from-quicksight.rb', __dir__)
DS = 'Widget Sales'

def measure(fid, col, agg)
  { 'NumericalMeasureField' => { 'FieldId' => fid,
                                 'Column' => { 'DataSetIdentifier' => DS, 'ColumnName' => col },
                                 'AggregationFunction' => { 'SimpleNumericalAggregation' => agg } } }
end

def dimension(fid, col)
  { 'CategoricalDimensionField' => { 'FieldId' => fid,
                                     'Column' => { 'DataSetIdentifier' => DS, 'ColumnName' => col } } }
end

def calc_measure(fid, name)
  { 'NumericalMeasureField' => { 'FieldId' => fid,
                                 'Column' => { 'DataSetIdentifier' => DS, 'ColumnName' => name },
                                 'AggregationFunction' => { 'SimpleNumericalAggregation' => 'SUM' } } }
end

def title(text)
  { 'FormatText' => { 'PlainText' => text } }
end

# Two KPIs (SUM + COUNT), a KPI over a WINDOW calc field, and two charts sharing the
# same dimension (so column-id uniqueness is exercised), plus one filter control.
ANALYSIS = {
  'Name' => 'Widget Overview',
  'Definition' => {
    'DataSetIdentifierDeclarations' => [{ 'Identifier' => DS, 'DataSetArn' => 'arn:aws:quicksight:us-east-1:000000000000:dataset/widget' }],
    'CalculatedFields' => [
      { 'DataSetIdentifier' => DS, 'Name' => 'Running Revenue',
        'Expression' => 'runningSum(sum({REVENUE}))' }
    ],
    'FilterGroups' => [
      { 'FilterGroupId' => 'fg-region',
        'Filters' => [{ 'CategoryFilter' => { 'FilterId' => 'flt-region',
                                              'Column' => { 'DataSetIdentifier' => DS, 'ColumnName' => 'REGION' },
                                              'Configuration' => { 'FilterListConfiguration' => { 'MatchOperator' => 'CONTAINS', 'SelectAllOptions' => 'FILTER_ALL_VALUES', 'NullOption' => 'ALL_VALUES' } } } }],
        'ScopeConfiguration' => { 'SelectedSheets' => { 'SheetVisualScopingConfigurations' => [{ 'SheetId' => 'sheet1', 'Scope' => 'ALL_VISUALS' }] } },
        'Status' => 'ENABLED', 'CrossDataset' => 'SINGLE_DATASET' }
    ],
    'Sheets' => [
      { 'SheetId' => 'sheet1', 'Name' => 'Widget Overview',
        'FilterControls' => [
          { 'Dropdown' => { 'FilterControlId' => 'ctl-region', 'Title' => 'Region',
                            'SourceFilterId' => 'flt-region', 'Type' => 'MULTI_SELECT' } }
        ],
        'Visuals' => [
          { 'KPIVisual' => { 'VisualId' => 'kpiRevenue', 'Title' => title('Total Revenue'),
                             'ChartConfiguration' => { 'FieldWells' => { 'Values' => [measure('m1', 'REVENUE', 'SUM')] } } } },
          { 'KPIVisual' => { 'VisualId' => 'kpiOrders', 'Title' => title('Order Count'),
                             'ChartConfiguration' => { 'FieldWells' => { 'Values' => [measure('m2', 'ORDER_ID', 'COUNT')] } } } },
          { 'KPIVisual' => { 'VisualId' => 'kpiRunning', 'Title' => title('Running Revenue'),
                             'ChartConfiguration' => { 'FieldWells' => { 'Values' => [calc_measure('m3', 'Running Revenue')] } } } },
          { 'BarChartVisual' => { 'VisualId' => 'barRegion', 'Title' => title('Revenue by Region'),
                                  'ChartConfiguration' => { 'FieldWells' => { 'BarChartAggregatedFieldWells' => {
                                    'Category' => [dimension('d1', 'REGION')], 'Values' => [measure('m4', 'REVENUE', 'SUM')] } } } } },
          # SAME dimension as the bar chart: the two charts must NOT collide on column ids.
          { 'LineChartVisual' => { 'VisualId' => 'lineRegion', 'Title' => title('Orders by Region'),
                                   'ChartConfiguration' => { 'FieldWells' => { 'LineChartAggregatedFieldWells' => {
                                     'Category' => [dimension('d2', 'REGION')], 'Values' => [measure('m5', 'ORDER_ID', 'COUNT')] } } } } }
        ] }
    ]
  }
}.freeze

READBACK = {
  'pages' => [{ 'elements' => [
    { 'id' => 'dmel-widget', 'name' => 'Widget Sales',
      'columns' => %w[REVENUE ORDER_ID REGION].map { |c| { 'name' => c } } }
  ] }]
}.freeze

def build(dir, tag)
  out = File.join(dir, "wb-#{tag}.json")
  _o, err, st = Open3.capture3('ruby', BUILDER,
                               '--analysis', File.join(dir, 'analysis.json'),
                               '--dm-readback', File.join(dir, 'dm-readback.json'),
                               '--out', out, '--folder-id', 'folder-test')
  raise "builder failed (#{st.exitstatus}):\n#{err}" unless File.exist?(out)
  [JSON.parse(File.read(out)), err]
end

# Every id in the spec, paired with what it belongs to, in document order.
def id_space(spec)
  out = []
  (spec['pages'] || []).each do |pg|
    out << ['page', pg['id']]
    (pg['elements'] || []).each do |e|
      out << ['element', e['id'], e['kind']]
      (e['columns'] || []).each { |c| out << ['column', e['id'], c['id']] }
      (e['filters'] || []).each { |f| out << ['filter', e['id'], f['id']] }
      (e['groupings'] || []).each { |g| out << ['grouping', e['id'], g['id']] }
    end
  end
  out
end

def kpi_cols(spec)
  (spec['pages'] || []).flat_map { |pg| pg['elements'] || [] }
                       .select { |e| e['kind'] == 'kpi-chart' }
                       .map { |e| [e['name'], e['columns'].first] }.to_h
end

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'analysis.json'), JSON.pretty_generate(ANALYSIS))
  File.write(File.join(dir, 'dm-readback.json'), JSON.pretty_generate(READBACK))

  a, _ = build(dir, 'a')
  b, _ = build(dir, 'b')

  # ── #541 ───────────────────────────────────────────────────────────────────
  ok('id space is IDENTICAL across two builds of the same analysis (#541)') do
    id_space(a) == id_space(b)
  end
  # Fixed page/element names the builder assigns on purpose (not generated ids).
  LITERAL_IDS = %w[master page-data page-dash].freeze
  ok('every GENERATED id is a stable digest, not a random hex blob') do
    # id_space rows are ['page', id] / ['element', id, kind] / ['column'|'filter'|
    # 'grouping', owner_id, id] — the id is row[1] for the first two, row[2] otherwise.
    ids = id_space(a).map { |row| %w[page element].include?(row[0]) ? row[1] : row[2] }.compact
    bad = ids.reject { |i| LITERAL_IDS.include?(i) || i.match?(/\A[a-z]+-[0-9a-f]{10}(-\d+)?\z/) }
    warn "  unexpected id shape(s): #{bad.inspect}" unless bad.empty?
    ids.any? && bad.empty?
  end
  ok('element ids are keyed to the QuickSight VisualId (5 visuals -> 5 chart elements)') do
    kinds = (a['pages'] || []).flat_map { |pg| pg['elements'] || [] }
                              .reject { |e| %w[control table].include?(e['kind']) }
    kinds.size == 5
  end
  ok('the control element id is stable across builds') do
    ctl = ->(s) { (s['pages'] || []).flat_map { |pg| pg['elements'] || [] }.select { |e| e['kind'] == 'control' }.map { |e| e['id'] } }
    ctl.(a) == ctl.(b) && !ctl.(a).empty?
  end
  ok('two charts sharing one dimension still get DISTINCT column ids (uniqueness kept)') do
    cols = (a['pages'] || []).flat_map { |pg| pg['elements'] || [] }
                             .reject { |e| e['kind'] == 'control' }
                             .flat_map { |e| (e['columns'] || []).map { |c| c['id'] } }
    cols.size == cols.uniq.size
  end
  ok('a visualId -> element map is emitted and matches the spec ids') do
    map_path = File.join(dir, 'wb-a.map.json')
    next false unless File.exist?(map_path)
    m = JSON.parse(File.read(map_path))['visualToElement'] || {}
    spec_ids = id_space(a).select { |r| r[0] == 'element' }.map { |r| r[1] }
    m.key?('kpiRevenue') && m.values.all? { |v| spec_ids.include?(v) }
  end

  # ── #542 ───────────────────────────────────────────────────────────────────
  k = kpi_cols(a)
  ok('KPI over SUM gets a grouped 2-decimal format (#542)') do
    k['Total Revenue'] && k['Total Revenue'].dig('format', 'formatString') == ',.2f'
  end
  ok('KPI over COUNT gets a grouped 0-decimal format (integral aggregation)') do
    k['Order Count'] && k['Order Count'].dig('format', 'formatString') == ',.0f'
  end
  ok('the decimal choice comes from the AGGREGATION, not the column name') do
    # "Total Revenue"/"Order Count" would both look money-ish/count-ish by name; the
    # discriminator must be the built formula's aggregate.
    k['Total Revenue']['formula'].to_s.match?(/\ASum\(/i) &&
      k['Order Count']['formula'].to_s.match?(/\ACount\(/i)
  end
  ok('a neutralized window-calc KPI is left UNFORMATTED (nothing to group)') do
    rc = k['Running Revenue']
    rc && rc['formula'].to_s.strip.casecmp('Null').zero? && rc['format'].nil?
  end
  ok('non-KPI chart measures are NOT given a format (QS abbreviated labels preserved)') do
    (a['pages'] || []).flat_map { |pg| pg['elements'] || [] }
                      .select { |e| %w[bar-chart line-chart].include?(e['kind']) }
                      .flat_map { |e| e['columns'] || [] }
                      .none? { |c| c['format'] }
  end
end

puts($fail.zero? ? "\nALL PASS — ids are deterministic (#541) and KPI big-numbers are grouped by aggregation (#542)" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
