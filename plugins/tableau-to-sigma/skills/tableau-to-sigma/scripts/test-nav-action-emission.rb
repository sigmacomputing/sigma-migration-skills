#!/usr/bin/env ruby
# A Tableau <nav-action> fires from a MARK CLICK on a worksheet. PR #657 wired
# only dashboard-object BUTTONS, so every mark-click nav-action stayed residue
# even though on-select -> navigate is runtime-proven.
#
# Deterministic + offline: drives the committed postpublish-actions.twb.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))

  nav = entries.find { |e| e['kind'] == 'nav-action' }
  check(!nav.nil?, 'the fixture still contains a nav-action')

  puts '== The stale spec-persistability note is gone ==========================='
  note = Array(nav['notes']).join(' ')
  check(!note.include?('not spec-persistable'),
        'the nav-action entry no longer claims navigation is "not spec-persistable" — ' \
        "that is the pre-#657 belief, disproven by the live probe (got: #{note.inspect})")

  puts '== The gate conditions are all present on the entry ====================='
  check(nav['trigger'] == 'on select',
        "trigger is Tableau's spaced form (got #{nav['trigger'].inspect}) — " \
        'emission must map it to Sigma\'s hyphenated on-select, not pass it through')
  check(Array(nav.dig('source', 'worksheets')).first == 'Sales by Region',
        'the source names a single worksheet, which is the join key to _worksheet')
  check(nav['targets'].first['dashboard'] == true,
        'the target is a DASHBOARD (a worksheet target has no element-id index)')

  puts '== The action is actually EMITTED onto the source element ==============='
  layout = File.join(d, 'layout.json')
  meta   = File.join(d, 'layout-meta.json')
  # parse-twb-layout.rb takes positional args (<twb> <out.json>), not
  # --twb/--out flags — matches its own usage banner and the existing correct
  # call site in test-action-detection-bridge.rb.
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  # build-charts-from-signals.rb requires --master-map (abort otherwise) and
  # the Phase 1d dashboard-read gate artifact (png-read.json) — same fixture
  # setup test-action-detection-bridge.rb already uses for this exact .twb.
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
               '(?i)^Region$'       => { 'id' => 'm-region',  'name' => 'Region' },
               '(?i)^Order ID$'     => { 'id' => 'm-orderid', 'name' => 'Order ID' },
               '(?i)^Category$'     => { 'id' => 'm-cat',     'name' => 'Category' },
               '(?i)^Sub-Category$' => { 'id' => 'm-subcat',  'name' => 'Sub-Category' },
               '(?i)^Product Name$' => { 'id' => 'm-prod',    'name' => 'Product Name' }
             ))
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => [
                 { 'id' => 'v1', 'name' => 'Sales by Region' },
                 { 'id' => 'v2', 'name' => 'Region Detail' },
                 { 'id' => 'v3', 'name' => 'Metric Buttons' },
                 { 'id' => 'v4', 'name' => 'Filter Panel Sheet' }
               ] }
             ))
  Dir.mkdir(File.join(d, 'views'))
  %w[v2 v3 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  # 'Sales by Region' (v1) needs REAL rows, not an empty stub: the fixture's
  # worksheet XML carries no <rows>/<cols> shelf signals (it's a minimal
  # detection-only fixture), so synthesize_view_from_signals can't reconstruct
  # it from an empty CSV and the zone would be dropped before any element
  # exists to host the nav-action — a 0-byte CSV proves detection-bridge
  # wiring (test-action-detection-bridge.rb's use case) but not emission.
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => [
                 { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                 { 'title' => 'Region Detail',      'kind' => 'table' },
                 { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                 { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
               ],
               'text_elements' => [], 'filter_shelf' => []
             ))

  charts = File.join(d, 'chart-specs.json')
  blog, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                              '--tableau-dir', d, '--layout', layout, '--meta', meta,
                              '--master-map', mmap, '--master-element-id', 'master',
                              '--page-per-dashboard',
                              '--detected-actions', detected,
                              '--out', charts)
  check(bst.success?, 'the chart build succeeded with --detected-actions' +
        (bst.success? ? '' : " (log:\n#{blog})"))

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  navs = emitted.select { |e| e.dig('source', 'kind') == 'nav-action' }
  check(navs.length == 1, "exactly one nav-action was emitted (got #{navs.length})")

  if (n = navs.first)
    check(n['trigger'] == 'on-select',
          "the emitted trigger is Sigma's hyphenated on-select (got #{n['trigger'].inspect})")
    check(n['effects'].first['effect'] == 'navigate', 'the effect is navigate')
    check(n['targetPageName'] == 'Detail Page',
          'targetPageName carries the raw dashboard name for put-layout.rb to resolve by name')
    check(n.dig('source', 'actionName') == '[Action4_DDDD]',
          'actionName is carried so ActionLedger.key_of can disambiguate same-captioned actions')
    ids = emitted.map { |e| e['actionId'] }
    check(ids.uniq.length == ids.length,
          'every emitted action id is unique across the whole workbook')
  end
end

puts
puts '== Regression: emitted_action_index survives the --page-per-dashboard rename pass =='
puts '   (build-charts-from-signals.rb els.map! ~:8594-8626, sibling to namespace_ids'
puts '   ~:8558-8586 — the reviewer-confirmed gap.)'
# A LITERAL "same worksheet reused verbatim on two dashboards" case can never
# exercise this path: element building is dashboard-major and single-pass
# (one `layout.each do |dash|` loop, :4283-~6500), so the FIRST dashboard (in
# `layout`/`dash_order` order) that carries a worksheet is BOTH what
# `elements.find` returns as host_el AND what the per-dashboard dedup pass
# visits first (and therefore leaves unrenamed) — they can never diverge.
#
# What DOES trigger the dedup rename on host_el itself is an id-STEM
# COLLISION with an unrelated, EARLIER-dashboard element. Element ids are
# `"el-#{caption.downcase.gsub(/\W+/, '-')[0..40]}"` (build-charts-from-
# signals.rb ~:2593/4516/4904) — a run of ANY non-word characters collapses
# to ONE hyphen, so "Sales by Region" (single space) and "Sales  by  Region"
# (double space) slug to the IDENTICAL "el-sales-by-region", while remaining
# DIFFERENT strings for the exact `_worksheet` match our emission code uses.
# So: put the double-spaced DECOY on Overview (dash_order[0] — claims the
# stem first, stays unrenamed) and the real, single-spaced "Sales by Region"
# — our nav-action's actual host — on Detail Page (dash_order[1] — the dedup
# pass finds the stem already claimed and RENAMES it). This is exactly the
# mechanism the review traced: host_el's own embedded actions[].id survives
# (whole-object gsub), but the OUT-OF-BAND emitted_actions manifest entry
# does not update unless els.map! also syncs emitted_action_index.
Dir.mktmpdir do |d2|
  layout2 = File.join(d2, 'layout.json')
  out2, st2 = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout2)
  check(st2.success?, "setup: parse-twb-layout succeeded (log:\n#{out2})")

  layout_data = JSON.parse(File.read(layout2))
  overview = layout_data.find { |dd| dd['dashboard'] == 'Overview' }
  detail   = layout_data.find { |dd| dd['dashboard'] == 'Detail Page' }
  check(!overview.nil? && !detail.nil?, 'setup: fixture has both Overview and Detail Page dashboards')

  sales_zone = (overview['zones'] || []).find { |z| z['caption'] == 'Sales by Region' }
  check(!sales_zone.nil?, 'setup: Overview has the Sales by Region zone to clone')

  if sales_zone
    # Clone BEFORE renaming the original: this becomes the REAL host zone,
    # placed on Detail Page (dash_order[1] — processed, and renamed, second).
    real_zone = JSON.parse(sales_zone.to_json)
    real_zone['id'] = 'zone-real-9002'
    detail['zones'] << real_zone

    # The decoy stays on Overview (dash_order[0]) under the id-colliding
    # double-spaced caption, so it claims "el-sales-by-region" first.
    sales_zone['caption'] = 'Sales  by  Region'
  end

  File.write(layout2, JSON.generate(layout_data))

  # get-workbook.json needs a view per exact caption — 'Sales by Region'
  # (the real host, on Detail Page) resolves via v1; the decoy needs its own.
  File.write(File.join(d2, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => [
                 { 'id' => 'v1', 'name' => 'Sales by Region' },
                 { 'id' => 'v2', 'name' => 'Region Detail' },
                 { 'id' => 'v3', 'name' => 'Metric Buttons' },
                 { 'id' => 'v4', 'name' => 'Filter Panel Sheet' },
                 { 'id' => 'v5', 'name' => 'Sales  by  Region' }
               ] }
             ))
  Dir.mkdir(File.join(d2, 'views'))
  %w[v2 v3 v4].each { |v| File.write(File.join(d2, 'views', "#{v}.csv"), '') }
  File.write(File.join(d2, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d2, 'views', 'v5.csv'), "Region,Profit Ratio\nEast,0.37\n")

  mmap2 = File.join(d2, 'master-map.json')
  File.write(mmap2, JSON.dump(
               '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' }
             ))
  File.write(File.join(d2, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => [{ 'title' => 'Sales by Region', 'kind' => 'bar-chart', 'orientation' => 'vertical' }],
               'text_elements' => [], 'filter_shelf' => []
             ))

  detected2 = File.join(d2, 'detected-actions.json')
  File.write(detected2, JSON.generate([
    { 'kind' => 'nav-action', 'caption' => 'GoTo Detail (rename-path)',
      'source' => { 'dashboard' => 'Detail Page', 'worksheets' => ['Sales by Region'] },
      'trigger' => 'on select',
      'targets' => [{ 'name' => 'Overview', 'dashboard' => true }],
      'actionName' => '[Action99_RENAME]' }
  ]))

  charts2 = File.join(d2, 'chart-specs.json')
  blog2, bst2 = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                                '--tableau-dir', d2, '--layout', layout2,
                                '--master-map', mmap2, '--master-element-id', 'master',
                                '--page-per-dashboard',
                                '--detected-actions', detected2,
                                '--out', charts2)
  check(bst2.success?, 'the rename-path chart build succeeded' +
        (bst2.success? ? '' : " (log:\n#{blog2})"))

  if bst2.success?
    spec2 = JSON.parse(File.read(charts2))
    manifest2 = JSON.parse(File.read(charts2.sub(/\.json$/, '-actions-emitted.json')))
    nav2 = manifest2.find { |e| e.dig('source', 'kind') == 'nav-action' }
    check(!nav2.nil?, 'the rename-path nav-action was emitted (not residue)')

    if nav2
      # This mirrors put-layout.rb:224's EXACT lookup
      # (`manifest.find { |m| m['actionId'] == a['id'] }` against the posted
      # spec) — a nil here IS the silent-skip bug: put-layout.rb's repair
      # block would `next` with no warning, leaving the provisional page id
      # live in the published workbook.
      posted_el = spec2['pages'].flat_map { |p| p['elements'] || [] }
                    .find { |e| (e['actions'] || []).any? { |a| a['id'] == nav2['actionId'] } }
      check(!posted_el.nil?,
            "manifest actionId #{nav2['actionId'].inspect} matches an action actually embedded in the " \
            'POSTED spec (put-layout.rb\'s exact lookup — nil here is the silent-skip bug)')
      check(!posted_el.nil? && posted_el['id'] == nav2['hostElementId'],
            "manifest hostElementId (#{nav2['hostElementId'].inspect}) matches the posted element's " \
            "actual id (#{posted_el && posted_el['id'].inspect}) after the rename")
      check(!posted_el.nil? && posted_el['id'] != 'el-sales-by-region',
            'sanity: the host element id stem WAS actually renamed by the dedup pass ' \
            "(got #{posted_el && posted_el['id'].inspect}) — otherwise this test exercises nothing")
    end
  end
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
