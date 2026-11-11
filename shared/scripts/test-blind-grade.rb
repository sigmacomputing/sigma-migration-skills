#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline regression tests for lib/blind_grade.rb (v1 + v2 grader, catalog,
# census non-chart families).

require 'json'
require 'digest'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative '../lib/blind_grade'

$failures = 0

def ok(name, condition)
  puts "#{condition ? '  ok  ' : 'FAIL  '}#{name}"
  $failures += 1 unless condition
end

def write_json(path, value)
  File.write(path, JSON.pretty_generate(value))
end

DIMS = BlindGrade::DIMENSION_KEYS

Dir.mktmpdir('blind-grade-test') do |d|
  File.binwrite(File.join(d, 'src.png'), 'source-pixels')
  File.binwrite(File.join(d, 'tgt.png'), 'target-pixels')
  src_sha = Digest::SHA256.file(File.join(d, 'src.png')).hexdigest
  tgt_sha = Digest::SHA256.file(File.join(d, 'tgt.png')).hexdigest

  cat_path = File.join(d, 'catalog.json')
  write_json(cat_path, 'version' => 1, 'entries' => [
    { 'id' => 'legend-inside-chart', 'dimension' => 'composition_match',
      'description' => 'legend inside chart frame', 'evidence' => 'no field',
      'last_verified' => '2026-11-05' },
    { 'id' => 'font-family', 'dimension' => 'palette_match', 'description' => 'typeface',
      'evidence' => 'no field', 'last_verified' => '2026-11-05', 'source_tools' => ['tableau'] }
  ])
  cat = BlindGrade.load_catalog(cat_path)
  ok('catalog loads clean', cat['errors'].empty?)
  ok('catalog ids', cat['ids'].sort == %w[font-family legend-inside-chart])
  ok('catalog sha is file-bytes sha256', cat['sha256'] == Digest::SHA256.file(cat_path).hexdigest)
  ok('missing catalog -> errors', !BlindGrade.load_catalog(File.join(d, 'nope.json'))['errors'].empty?)
  File.write(File.join(d, 'bad.json'), '{nope')
  ok('unparseable catalog -> errors', !BlindGrade.load_catalog(File.join(d, 'bad.json'))['errors'].empty?)
  write_json(File.join(d, 'bad2.json'), 'version' => 1, 'entries' => [
    { 'id' => 'a', 'dimension' => 'nonsense', 'description' => 'x', 'evidence' => '', 'last_verified' => 'yesterday' },
    { 'id' => 'a', 'dimension' => 'palette_match', 'description' => 'x', 'evidence' => 'y',
      'last_verified' => '2026-11-05', 'source_tools' => 'tableau' }
  ])
  b2 = BlindGrade.load_catalog(File.join(d, 'bad2.json'))
  ok('catalog shape errors (dimension, evidence, date, dup id, source_tools)', b2['errors'].size >= 5)
  ok('bad catalog exposes no ids', b2['ids'].empty?)

  base_dims = DIMS.each_with_object({}) { |k, h| h[k] = { 'verdict' => 'pass' } }
  per_tile = [{ 'position' => 1, 'source_family' => 'bar', 'target_family' => 'bar' }]

  v1 = { 'source_png' => 'src.png', 'target_png' => 'tgt.png', 'source_sha256' => src_sha,
         'target_sha256' => tgt_sha, 'dimensions' => base_dims, 'per_tile' => per_tile, 'verdict' => 'pass' }
  v1_path = File.join(d, 'v1.json')
  write_json(v1_path, v1)
  ok('v1 grade validates unchanged', BlindGrade.load_and_validate(v1_path, workdir: d)['errors'].empty?)
  ok('v1 ignores catalog arg', BlindGrade.load_and_validate(v1_path, workdir: d, catalog: cat)['errors'].empty?)
  write_json(v1_path, v1.merge('schema' => 'blind-grade/v1'))
  ok('explicit v1 schema validates', BlindGrade.load_and_validate(v1_path, workdir: d)['errors'].empty?)
  write_json(v1_path, v1.reject { |k, _| k == 'verdict' })
  ok('v1 still requires verdict', !BlindGrade.load_and_validate(v1_path, workdir: d)['errors'].empty?)
  write_json(v1_path, v1.merge('schema' => 'blind-grade/v9'))
  ok('unknown schema is an error',
     BlindGrade.load_and_validate(v1_path, workdir: d)['errors'].any? { |e| e.include?('schema') })

  scores = DIMS.each_with_object({}) { |k, h| h[k] = 8 }
  mk = lambda do |score, over = {}|
    { 'schema' => 'blind-grade/v2', 'source_png' => 'src.png', 'target_png' => 'tgt.png',
      'source_sha256' => src_sha, 'target_sha256' => tgt_sha, 'catalog_sha256' => cat['sha256'],
      'dimensions' => base_dims, 'per_tile' => per_tile, 'scores' => scores,
      'overall_score' => score, 'gaps' => [] }.merge(over)
  end
  load_v2 = lambda do |doc, catalog = cat|
    p = File.join(d, "v2-#{rand(1_000_000)}.json")
    write_json(p, doc)
    BlindGrade.load_and_validate(p, workdir: d, catalog: catalog)
  end

  ok('v2 minimal doc validates (no verdict needed)', load_v2.call(mk.call(80))['errors'].empty?)
  ok('v2 without catalog refused',
     load_v2.call(mk.call(80), nil)['errors'].any? { |e| e.include?('catalog required for blind-grade/v2') })
  ok('v2 bad verdict refused', !load_v2.call(mk.call(80, 'verdict' => 'maybe'))['errors'].empty?)
  ok('v2 verdict pass allowed', load_v2.call(mk.call(80, 'verdict' => 'pass'))['errors'].empty?)

  errs = load_v2.call(mk.call(80, 'gaps' => [{ 'tile' => 't', 'dimension' => 'composition_match',
                                              'description' => 'x', 'severity' => 'minor',
                                              'class' => 'no-such-id' }]))['errors']
  ok('v2 unknown catalog id refused', errs.any? { |e| e.include?('unknown catalog id') && e.include?('no-such-id') })
  errs = load_v2.call(mk.call(80, 'catalog_sha256' => 'f' * 64))['errors']
  ok('v2 catalog sha mismatch refused',
     errs.any? { |e| e.include?('catalog_sha256') && e.include?('f' * 64) && e.include?(cat['sha256']) })
  ok('v2 score out of range', !load_v2.call(mk.call(101))['errors'].empty?)
  ok('v2 non-integer score', !load_v2.call(mk.call(80.5))['errors'].empty?)
  bad_scores = scores.dup
  bad_scores.delete('palette_match')
  ok('v2 missing score key', !load_v2.call(mk.call(80, 'scores' => bad_scores))['errors'].empty?)
  ok('v2 score 11 refused', !load_v2.call(mk.call(80, 'scores' => scores.merge('palette_match' => 11)))['errors'].empty?)
  ok('v2 gaps not array', !load_v2.call(mk.call(80, 'gaps' => 'none'))['errors'].empty?)
  ok('v2 bad severity', !load_v2.call(mk.call(80, 'gaps' => [{ 'tile' => 't', 'dimension' => 'palette_match',
                                                              'description' => 'x', 'severity' => 'huge',
                                                              'class' => 'fixable' }]))['errors'].empty?)
  ok('v2 sha binding still enforced', !load_v2.call(mk.call(80, 'source_sha256' => 'a' * 64))['errors'].empty?)

  fixable = lambda do |sev|
    { 'tile' => 't1', 'dimension' => 'composition_match', 'description' => 'gap', 'severity' => sev,
      'class' => 'fixable' }
  end
  platform = { 'tile' => 't2', 'dimension' => 'composition_match', 'description' => 'legend',
               'severity' => 'minor', 'class' => 'legend-inside-chart' }
  with_dims = lambda do |over|
    base_dims.merge(over)
  end

  doc80 = mk.call(80, 'gaps' => [fixable.call('minor'), platform])
  r = BlindGrade.faithful([doc80], cat)
  ok('faithful at 80, shapes+numbers pass, minor fixable only', r['faithful'] && r['residuals'].size == 1)
  ok('platform differences listed, not residuals',
     r['platform_differences'].map { |g| g['class'] } == ['legend-inside-chart'] &&
     r['residuals'].none? { |g| g['class'] == 'legend-inside-chart' })
  ok('score is a Float', r['score'] == 80.0 && r['score'].is_a?(Float))
  ok("80 is borderline (|80-75|<=5)", r["needs_second"])

  r = BlindGrade.faithful([mk.call(80, 'gaps' => [fixable.call('major')])], cat)
  ok('not faithful with a major fixable gap', !r['faithful'] && r['reasons'].any? { |x| x.include?('major fixable') })

  r = BlindGrade.faithful([mk.call(80, 'gaps' => [platform.merge('severity' => 'major')])], cat)
  ok('major platform-difference gap does not block', r['faithful'])

  r = BlindGrade.faithful([mk.call(90, 'dimensions' => with_dims.call('chart_shapes_match' => { 'verdict' => 'fail' }))], cat)
  ok('not faithful when chart_shapes_match fails at 90', !r['faithful'] && r['reasons'].any? { |x| x.include?('chart_shapes_match') })
  r = BlindGrade.faithful([mk.call(90, 'dimensions' => with_dims.call('numbers_formatted' => { 'verdict' => 'fail' }))], cat)
  ok('not faithful when numbers_formatted fails at 90', !r['faithful'] && r['reasons'].any? { |x| x.include?('numbers_formatted') })
  r = BlindGrade.faithful([mk.call(90, 'dimensions' => with_dims.call('palette_match' => { 'verdict' => 'fail' }))], cat)
  ok('other dimension fail does not block at 90', r['faithful'])
  r = BlindGrade.faithful([mk.call(60)], cat)
  ok('not faithful below 75', !r['faithful'] && !r['needs_second'])

  doc78 = mk.call(78)
  r = BlindGrade.faithful([doc78], cat)
  ok('borderline single grade needs second', r['needs_second'])
  ok('borderline single grade still computes faithful honestly', r['faithful'] == true)
  ok('boundary 70 needs second', BlindGrade.faithful([mk.call(70)], cat)['needs_second'])
  ok('boundary 80 needs second', BlindGrade.faithful([mk.call(80)], cat)['needs_second'])
  ok('69 does not need second', !BlindGrade.faithful([mk.call(69)], cat)['needs_second'])
  ok('81 does not need second', !BlindGrade.faithful([mk.call(81)], cat)['needs_second'])

  r2 = BlindGrade.faithful([mk.call(72), mk.call(80)], cat)
  ok('two grades use the mean (72,80 -> 76 faithful)', r2['faithful'] && r2['score'] == 76.0)
  ok('two grades never need a third', !r2['needs_second'])
  r2 = BlindGrade.faithful([mk.call(70), mk.call(78)], cat)
  ok('two grades mean 74 not faithful', !r2['faithful'] && r2['score'] == 74.0)
  r2 = BlindGrade.faithful([mk.call(90, 'gaps' => [fixable.call('major')]), mk.call(80)], cat)
  ok('major fixable in either doc blocks', !r2['faithful'])
  ok('faithful rejects 0 or 3 docs', (begin; BlindGrade.faithful([], cat); false; rescue ArgumentError; true; end) &&
                                    (begin; BlindGrade.faithful([doc78, doc78, doc78], cat); false; rescue ArgumentError; true; end))

  # --- final review: fixable_major, de-dup, catalog-id dimension (M3) --------
  maj = fixable.call('major')
  r = BlindGrade.faithful([mk.call(90, 'gaps' => [maj, fixable.call('minor')])], cat)
  ok('fixable_major lists major fixable gaps only', r['fixable_major'] == [maj] && r['residuals'].size == 1)
  r = BlindGrade.faithful([mk.call(90, 'gaps' => [maj, platform.merge('severity' => 'major')])], cat)
  ok('platform major is not in fixable_major', r['fixable_major'] == [maj])
  r = BlindGrade.faithful([mk.call(90, 'gaps' => [maj, fixable.call('minor')]),
                           mk.call(91, 'gaps' => [maj.dup, fixable.call('minor'), platform])], cat)
  ok('gaps de-duplicated across two graders (exact tile/dimension/description/severity/class)',
     r['fixable_major'].size == 1 && r['residuals'].size == 1 && r['platform_differences'].size == 1 &&
     r['reasons'].grep(/major fixable gap/).size == 1)
  r = BlindGrade.faithful([mk.call(90, 'gaps' => [maj, maj.merge('description' => 'other gap')])], cat)
  ok('different descriptions are not de-duplicated', r['fixable_major'].size == 2)
  errs = load_v2.call(mk.call(80, 'gaps' => [platform.merge('dimension' => 'palette_match')]))['errors']
  ok('M3: catalog-id gap on the wrong dimension refused, naming id and both dimensions',
     errs.any? { |e| e.include?('legend-inside-chart') && e.include?('composition_match') && e.include?('palette_match') })
  ok('M3: catalog-id gap on its own dimension accepted', load_v2.call(mk.call(80, 'gaps' => [platform]))['errors'].empty?)

  # --- census: Sigma nav/button/control elements are not charts -------------
  els = [{ 'id' => 'c1', 'kind' => 'bar-chart' }, { 'id' => 'c2', 'kind' => 'line-chart' }]
  9.times { |i| els << { 'id' => "b#{i}", 'kind' => 'button' } }
  els << { 'id' => 'nav', 'kind' => 'navigation' } << { 'id' => 'sp', 'kind' => 'spacer' }
  els << { 'id' => 'ctl', 'kind' => 'control' } << { 'id' => 'tc', 'kind' => 'tabbed-container' }
  rb_path = File.join(d, 'wb-readback.json')
  write_json(rb_path, 'pages' => [{ 'id' => 'p1', 'name' => 'Main', 'elements' => els.map { |e| e['id'] } }],
                      'elements' => els)
  census = BlindGrade.census_from_readback(rb_path)
  if census.nil?
    # Fall back to whatever shape Sigma::CodeRep accepts: flat elements without pages.
    write_json(rb_path, 'elements' => els)
    census = BlindGrade.census_from_readback(rb_path)
  end
  ok('census ignores buttons/navigation/spacer/control/tabbed-container',
     census == %w[bar line])
  two = [{ 'source_family' => 'bar', 'target_family' => 'bar' }, { 'source_family' => 'line', 'target_family' => 'line' }]
  ok('2 charts + 9 buttons vs per_tile of 2 charts -> 0 mismatches',
     BlindGrade.cross_check(two, census, 'target')['mismatches'] == 0)
  with_nav = two + [{ 'source_family' => 'button', 'target_family' => 'button' }]
  ok('blind per_tile may list buttons without penalty',
     BlindGrade.cross_check(with_nav, census, 'target')['mismatches'] == 0)
  %w[button navigation spacer tabbed-container repeated-container page-break form embed chat filter
     date-control list-control text-control number-range-control segmented-control].each do |k|
    ok("family(#{k}) is non-chart", !BlindGrade.chart_family?(BlindGrade.family(k)))
  end
  ok('unknown kind still counts as chart-ish other', BlindGrade.chart_family?(BlindGrade.family('mystery-viz')))
  ok('real charts unchanged', BlindGrade.family('bar-chart') == 'bar' && BlindGrade.family('pivot-table') == 'table')
  png = File.join(d, 'png-read.json')
  write_json(png, 'tiles' => [{ 'kind' => 'bar' }, { 'kind' => 'button' }, { 'kind' => 'navigation' }])
  ok('png-read census ignores buttons', BlindGrade.census_from_png_read(png) == %w[bar])
end

# --- KPI band rule: a strip of single-value KPIs may read as one band --------
RCC_CENSUS = %w[kpi kpi kpi line table bar bar table bar map].freeze
def tiles_of(fams)
  fams.each_with_index.map { |f, i| { 'position' => "t#{i}", 'source_family' => f, 'target_family' => f } }
end
RCC_G1 = tiles_of(%w[text navigation control kpi kpi kpi line table bar bar table bar map]).freeze
RCC_G2 = tiles_of(%w[text navigation control kpi line table bar bar table bar map]).freeze
%w[target source].each do |side|
  cc = BlindGrade.cross_check(RCC_G2, RCC_CENSUS, side)
  ok("KPI band (RCC grade 2, #{side}): 1 kpi tile vs 3 kpi census -> 0 mismatches + kpi_band",
     cc['mismatches'] == 0 && cc['kpi_band'] == true)
  ok("RCC grade 1 (#{side}, 3 kpi tiles) -> 0 mismatches, no band",
     BlindGrade.cross_check(RCC_G1, RCC_CENSUS, side)['mismatches'] == 0 &&
     !BlindGrade.cross_check(RCC_G1, RCC_CENSUS, side).key?('kpi_band'))
end
cc = BlindGrade.cross_check(tiles_of(%w[kpi kpi kpi line table line line table bar map]), RCC_CENSUS, 'target')
ok('real swap (two bars read as lines) still refused: mismatches 2', cc['mismatches'] == 2)
cc = BlindGrade.cross_check(tiles_of(%w[text text text line table bar bar table bar map]), RCC_CENSUS, 'target')
ok('census has 3 kpis, blind reads 0 kpi -> mismatches >= 2', cc['mismatches'] >= 2 && !cc.key?('kpi_band'))
cc = BlindGrade.cross_check(tiles_of(%w[kpi bar]), %w[bar bar], 'target')
ok('blind kpi where the census has none (bar read as kpi) -> still a mismatch', cc['mismatches'] == 1 && !cc.key?('kpi_band'))
cc = BlindGrade.cross_check(tiles_of(%w[kpi kpi kpi kpi kpi line]), %w[kpi kpi kpi line], 'target')
ok('band rule is symmetric: blind kpi=5 vs census kpi=3 -> 0 mismatches', cc['mismatches'] == 0 && cc['kpi_band'] == true)

# --- can't-tell: "other" / "unknown" is not a reading (Stress 4, 2026-11-09) ---
S4_CENSUS = %w[bar bar line line table kpi kpi map].freeze
cc = BlindGrade.cross_check(tiles_of(%w[bar bar line line table kpi other unknown]), S4_CENSUS, 'target')
ok("2 tiles filed other/unknown -> 0 mismatches, cant_tell 2 (#{cc.inspect})", cc['mismatches'] == 0 && cc['cant_tell'] == 2)
cc = BlindGrade.cross_check(tiles_of(%w[bar bar line line table kpi kpi map other]), S4_CENSUS, 'target')
ok('an extra can-not-tell tile beyond the census is not a contradiction', cc['mismatches'] == 0 && cc['cant_tell'] == 1)
cc = BlindGrade.cross_check(tiles_of(%w[line line line line table kpi other unknown]), S4_CENSUS, 'target')
ok("a real swap (2 bars read as lines) next to can't-tell tiles is still refused: mismatches 2 (#{cc['mismatches']})",
   cc['mismatches'] == 2)
cc = BlindGrade.cross_check(tiles_of(%w[bar bar line line table kpi treemap mystery]), S4_CENSUS, 'target')
ok('unrecognised kind strings (treemap) are NOT can-not-tell: still mismatches', cc['mismatches'] == 2 && !cc.key?('cant_tell'))
cc = BlindGrade.cross_check(tiles_of(%w[other other other other other other other other]), S4_CENSUS, 'target')
ok("all tiles can-not-tell read nothing -> still refused (#{cc['mismatches']} > #{BlindGrade::MAX_FAMILY_MISMATCHES})",
   cc['mismatches'] > BlindGrade::MAX_FAMILY_MISMATCHES)
ok('equal kpi counts -> no kpi_band key', !BlindGrade.cross_check(tiles_of(%w[kpi line]), %w[kpi line], 'target').key?('kpi_band'))

# The seeded catalog must be valid and every entry evidenced.
seed = File.expand_path('../refs/sigma-platform-differences.json', __dir__)
if File.file?(seed)
  sc = BlindGrade.load_catalog(seed)
  ok('seeded catalog has no shape errors', sc['errors'].empty?)
  ok('seeded catalog loads with no errors (entries may be empty)', sc['errors'].empty? && sc['sha256'])
  ok('every seeded entry (if any) has evidence + last_verified date',
     sc['entries'].all? { |e| !e['evidence'].to_s.strip.empty? && e['last_verified'].to_s =~ /\A\d{4}-\d{2}-\d{2}\z/ })
else
  ok('seeded catalog exists', false)
end

# An empty entries array is a valid catalog (entries are added only with proof).
Dir.mktmpdir('blind-grade-empty-cat') do |d2|
  ep = File.join(d2, 'c.json')
  File.write(ep, '{"version":1,"entries":[]}')
  ec = BlindGrade.load_catalog(ep)
  ok('empty-entries catalog is valid', ec['errors'].empty? && ec['ids'] == [] && ec['sha256'])
end

# The shipped catalog: pivot-row-height-fixed (2026-11-09) is a valid, narrow
# composition_match entry that scopes clipping/truncation out as fixable.
shipped = BlindGrade.load_catalog(File.expand_path('../refs/sigma-platform-differences.json', __dir__))
prh = Array(JSON.parse(File.read(File.expand_path('../refs/sigma-platform-differences.json', __dir__)))['entries'])
      .find { |e| e['id'] == 'pivot-row-height-fixed' }
ok('shipped catalog loads cleanly and lists pivot-row-height-fixed',
   shipped['errors'].empty? && shipped['ids'].include?('pivot-row-height-fixed'))
ok('pivot-row-height-fixed is composition_match and keeps clipped/truncated pivots fixable',
   prh && prh['dimension'] == 'composition_match' && prh['description'].include?('clipped or truncated') &&
   prh['description'].include?('fixable') && !prh['evidence'].to_s.strip.empty? && prh['last_verified'] == '2026-11-09')

# ── catalog history: the ancestor rule (BlindGrade.catalog_compat) ───────────
# A grade binds the catalog sha it was graded against. A catalog that only
# GAINED entries since keeps it valid; a removed/changed entry or an unknown
# sha refuses it. tools/gen-catalog-history.rb writes the history.
require_relative '../../tools/gen-catalog-history'
puts '== catalog history (ancestor rule) =='
ENTRY = lambda do |id, dim = 'composition_match', desc = "#{id} differs"|
  { 'id' => id, 'dimension' => dim, 'description' => desc, 'evidence' => 'probe', 'last_verified' => '2026-11-10' }
end
Dir.mktmpdir('catalog-history') do |root|
  rel = 'refs/sigma-platform-differences.json'
  hrel = 'refs/sigma-platform-differences-history.json'
  FileUtils.mkdir_p(File.join(root, 'refs'))
  cat_file = File.join(root, rel)
  gen = lambda do |entries|
    File.write(cat_file, JSON.pretty_generate('version' => 1, 'entries' => entries))
    text, sha = CatalogHistory.generate(root: root, catalog_rel: rel, history_rel: hrel, use_git: false)
    File.write(File.join(root, hrel), text)
    sha
  end
  a = [ENTRY.call('legend-inside'), ENTRY.call('font-family', 'labels_legible')]
  sha_a = gen.call(a)
  sha_b = gen.call(a + [ENTRY.call('row-height-fixed')])                       # B = A + one entry
  sha_chg = gen.call([ENTRY.call('legend-inside', 'composition_match', 'reworded'), a[1], ENTRY.call('x')])
  sha_rm = gen.call([a[1]])                                                    # legend-inside removed
  # The history is append-only: a rewrite back to B keeps every earlier record.
  gen.call(a + [ENTRY.call('row-height-fixed')])
  cat = BlindGrade.load_catalog(cat_file)
  ok('history loads clean and lists all 4 catalogs', cat['history_errors'].empty? && cat['history'].keys.sort == [sha_a, sha_b, sha_chg, sha_rm].sort)
  ok('history file passes its own --check (generation is idempotent)',
     CatalogHistory.generate(root: root, catalog_rel: rel, history_rel: hrel, use_git: false)[0] == File.read(File.join(root, hrel)))

  cur = BlindGrade.catalog_compat(sha_b, cat)
  ok('current sha still accepted (status current, no new ids)', cur['ok'] && cur['status'] == 'current' && cur['new_ids'].empty?)
  anc = BlindGrade.catalog_compat(sha_a.upcase, cat)
  ok('ancestor-subset accepted: status ancestor, new_ids = the added entry',
     anc['ok'] && anc['status'] == 'ancestor' && anc['new_ids'] == ['row-height-fixed'] &&
     anc['graded_ids'] == %w[legend-inside font-family])
  chg = BlindGrade.catalog_compat(sha_chg, cat)
  ok('changed entry refused (names the entry as CHANGED)',
     !chg['ok'] && chg['error'].include?('catalog_sha256 mismatch') && chg['error'].include?('legend-inside was CHANGED'))
  rm_c = gen.call(a.reverse) # current catalog that dropped row-height-fixed but kept A (reordered bytes)
  cat2 = BlindGrade.load_catalog(cat_file)
  rmv = BlindGrade.catalog_compat(sha_b, cat2)
  ok('removed entry refused (B had row-height-fixed; the shipped catalog dropped it)',
     !rmv['ok'] && rmv['error'].include?('row-height-fixed was REMOVED'))
  ok('a reordered catalog with identical entries accepts its predecessor (no new ids)',
     BlindGrade.catalog_compat(sha_a, cat2)['ok'] && BlindGrade.catalog_compat(sha_a, cat2)['new_ids'].empty? && rm_c != sha_a)
  unk = BlindGrade.catalog_compat('e' * 64, cat2)
  ok('unknown sha refused (not in the history)', !unk['ok'] && unk['error'].include?('unknown catalog') && unk['error'].include?('e' * 64))
  ok('nil sha refused', !BlindGrade.catalog_compat(nil, cat2)['ok'])

  # validate_v2: an ancestor grade validates; it may not cite an id added later.
  gen.call(a + [ENTRY.call('row-height-fixed')])
  cat = BlindGrade.load_catalog(cat_file)
  g = { 'scores' => DIMS.map { |k| [k, 8] }.to_h, 'overall_score' => 85, 'catalog_sha256' => sha_a,
        'gaps' => [{ 'tile' => 'r1', 'dimension' => 'labels_legible', 'description' => 'typeface', 'severity' => 'minor', 'class' => 'font-family' },
                   { 'tile' => 'r2', 'dimension' => 'composition_match', 'description' => 'rows taller', 'severity' => 'minor', 'class' => 'fixable' }] }
  ok('validate_v2: ancestor grade has no errors', BlindGrade.validate_v2(g, cat).empty?)
  late = g.merge('gaps' => [{ 'tile' => 'r2', 'dimension' => 'composition_match', 'description' => 'rows taller', 'severity' => 'minor', 'class' => 'row-height-fixed' }])
  errs = BlindGrade.validate_v2(late, cat)
  ok('validate_v2: ancestor grade citing an id added AFTER it is refused', errs.any? { |e| e.include?('added AFTER') && e.include?('row-height-fixed') })
  dec = BlindGrade.faithful([g], cat)
  ok('faithful keeps the ancestor grade gaps exactly as graded (fixable stays a residual, never re-mapped)',
     dec['residuals'].map { |x| x['class'] } == ['fixable'] && dec['platform_differences'].map { |x| x['class'] } == ['font-family'])
  ok('validate_v2: changed-entry grade refused', BlindGrade.validate_v2(g.merge('catalog_sha256' => sha_chg), cat).any? { |e| e.include?('CHANGED') })
  ok('validate_v2: unknown-sha grade refused', BlindGrade.validate_v2(g.merge('catalog_sha256' => 'e' * 64), cat).any? { |e| e.include?('catalog_sha256 mismatch') })

  # Fail closed: a malformed or missing history accepts only the exact sha.
  File.write(File.join(root, hrel), '{"schema":"sigma-platform-differences-history/v1","catalogs":[{"sha256":"zz"}]}')
  bad = BlindGrade.load_catalog(cat_file)
  ok('malformed history fails closed (no ancestor accepted; current still ok)',
     !BlindGrade.catalog_compat(sha_a, bad)['ok'] && BlindGrade.catalog_compat(sha_b, bad)['ok'] &&
     BlindGrade.catalog_compat(sha_a, bad)['error'].include?('unusable'))
  File.write(File.join(root, hrel), "<<<<<<< HEAD\n{}\n=======\n")
  _o, gen_err, gen_st = Open3.capture3(RbConfig.ruby, '-e', <<~RB, root, rel, hrel)
    require #{File.expand_path('../../tools/gen-catalog-history.rb', __dir__).inspect}
    CatalogHistory.generate(root: ARGV[0], catalog_rel: ARGV[1], history_rel: ARGV[2], use_git: false)
  RB
  ok('generator ABORTS on an unparseable existing history (never silently drops records)',
     !gen_st.success? && gen_err.include?('is not valid JSON'))
  File.delete(File.join(root, hrel))
  ok('missing history: ancestor refused, current accepted',
     !BlindGrade.catalog_compat(sha_a, BlindGrade.load_catalog(cat_file))['ok'] &&
     BlindGrade.catalog_compat(sha_b, BlindGrade.load_catalog(cat_file))['ok'])
end

# Canonical JSON (entry content hash) vectors — the Python twin
# (test_blind_grade_v2.py) pins the same strings.
ok('canonical_json sorts keys, escapes non-printable ASCII as lowercase \\u (UTF-16)',
   BlindGrade.canonical_json({ 'z' => "é— \u0001\u007f😀\"\\/", 'a' => [1, -2, true, false, nil, {}], 'B' => {} }) ==
   '{"B":{},"a":[1,-2,true,false,null,{}],"z":"\\u00e9\\u2014\\u2028\\u0001\\u007f\\ud83d\\ude00\\"\\\\/"}')
ok('a non-string catalog id is a catalog error (Ruby/Python would stringify it differently)',
   BlindGrade.parse_catalog_bytes(JSON.generate('version' => 1, 'entries' => [ENTRY.call('x').merge('id' => true)]))['errors']
             .any? { |e| e.include?('id must be a string') })
ok('canonical_json refuses floats', (begin; BlindGrade.canonical_json('x' => 1.5); false; rescue ArgumentError; true; end))

# The SHIPPED history is current (CI also runs tools/gen-catalog-history.rb --check).
ok('shipped history lists the shipped catalog and loads clean',
   shipped['history_errors'].empty? && shipped['history'].key?(shipped['sha256']) &&
   shipped['history'][shipped['sha256']] == shipped['entry_hashes'])

puts($failures.zero? ? 'ALL PASS' : "#{$failures} FAILURE(S)")
exit($failures.zero? ? 0 : 1)
