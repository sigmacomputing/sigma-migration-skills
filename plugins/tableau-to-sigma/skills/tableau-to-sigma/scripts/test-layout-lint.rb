#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline regression tests for lib/layout_lint.rb (the shared layout-quality
# gate, vendored byte-identical across every migration plugin). Creds-free —
# runs in the corpus-check unit-tests job.
#
# Guards in particular the vertical-rail false-positive: a nested container
# declaring gridTemplateColumns="repeat(1, 1fr)" whose children fill its single
# column must read as 100% full, NOT 1/24. That bug hard-failed every dashboard
# with a left filter rail / sidebar (caught end-to-end against a real shipped
# workbook before this test existed).

require_relative 'lib/layout_lint'

$failures = 0
def check(name)
  v = yield
  if v
    puts "  ok  - #{name}"
  else
    puts "  FAIL- #{name}"
    $failures += 1
  end
end

def lint(spec)
  # Keep the scenario declarations compact while exercising the released
  # workbook contract: metadata-only pages, flat document.elements, and the
  # canonical Element/Container layout tags.
  pages = Array(spec['pages'])
  elements = pages.flat_map { |page| Array(page['elements']) }
  document = {
    'schemaVersion' => 2,
    'kind' => 'workbook',
    'pages' => pages.map { |page| page.reject { |key, _| key == 'elements' } },
    'elements' => elements,
    'layout' => spec['layout'].to_s
                              .gsub('<GridContainer', '<Container')
                              .gsub('</GridContainer>', '</Container>')
                              .gsub('<LayoutElement', '<Element')
  }
  LayoutLint.lint('document' => document)
end

def has?(viol, frag)
  viol.any? { |x| x.include?(frag) }
end

# --- 1. vertical rail (repeat(1,1fr)) is CLEAN — the regression -------------
rail = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Container elementId="hero" type="grid" gridColumn="1 / 25" gridRow="1 / 5" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
      </Container>
      <Container elementId="rail" type="grid" gridColumn="1 / 6" gridRow="5 / 30" gridTemplateColumns="repeat(1, 1fr)">
        <Element elementId="ctlA" gridColumn="1 / 2" gridRow="1 / 6"/>
        <Element elementId="ctlB" gridColumn="1 / 2" gridRow="6 / 11"/>
      </Container>
      <Container elementId="content" type="grid" gridColumn="6 / 25" gridRow="5 / 30" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="t1" gridColumn="1 / 25" gridRow="1 / 25"/>
      </Container>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'Partner Summary', 'elements' => [
    { 'id' => 'title', 'kind' => 'text', 'body' => '# enterprise Partner Bookings' },
    { 'id' => 'ctlA', 'kind' => 'control', 'name' => 'Region' },
    { 'id' => 'ctlB', 'kind' => 'control', 'name' => 'Channel' },
    { 'id' => 't1', 'kind' => 'pivot-table', 'name' => 'By Partner' }
  ] }]
}
rv = lint(rail)
check('vertical rail (repeat(1,1fr)) lints clean') { rv.empty? }

# --- 2. a genuinely under-filled 24-col band still FAILS --------------------
bad = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Container elementId="hdr" type="grid" gridColumn="1 / 25" gridRow="1 / 3" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="hdrtext" gridColumn="1 / 25" gridRow="1 / 3"/>
      </Container>
      <Container elementId="band1" type="grid" gridColumn="1 / 25" gridRow="3 / 9" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="smallbar" gridColumn="1 / 6" gridRow="1 / 6"/>
      </Container>
      <Element elementId="loosectl" gridColumn="1 / 5" gridRow="20 / 22"/>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'Partner Summary', 'elements' => [
    { 'id' => 'hdrtext', 'kind' => 'text', 'body' => '# Page 1' },
    { 'id' => 'smallbar', 'kind' => 'bar-chart', 'name' => 'a1b2c3d4e5f6' },
    { 'id' => 'loosectl', 'kind' => 'control', 'name' => 'Region' }
  ] }]
}
bv = lint(bad)
check('under-filled 24-col band fails')      { has?(bv, 'band under-filled') }
check('raw-id display name flagged')         { has?(bv, 'raw-id display name') }
check('orphan control flagged')              { has?(bv, 'orphan control') }
check('generic header title flagged')        { has?(bv, 'generic header title') }
check('dead zone flagged')                   { has?(bv, 'dead zone') }

# --- 2b. a top-level control ABOVE the first section band is NOT orphaned ----
# The exemplar "filter over a banded grid" pattern (Metric Series):
# a bare Region control in the control region above the first tinted band. It is
# legitimate, not lost among the charts, so it must lint clean.
ctl_above = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 3"/>
      <Element elementId="region" gridColumn="1 / 7" gridRow="3 / 6"/>
      <Container elementId="c-band" type="grid" gridColumn="1 / 9" gridRow="6 / 8" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="band" gridColumn="1 / 25" gridRow="1 / 3"/>
      </Container>
      <Element elementId="chart" gridColumn="1 / 9" gridRow="8 / 19"/>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'Indicators', 'elements' => [
    { 'id' => 'title', 'kind' => 'text', 'body' => '**Metric Series**' },
    { 'id' => 'region', 'kind' => 'control', 'name' => 'Region' },
    { 'id' => 'band', 'kind' => 'text', 'body' => 'YEAR ON YEAR' },
    { 'id' => 'chart', 'kind' => 'bar-chart', 'name' => 'REV YEAR ON YEAR' }
  ] }]
}
check('control above first band NOT orphaned') { !has?(lint(ctl_above), 'orphan control') }

# --- 3. explicit multi-track template counts its own tracks -----------------
three = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Container elementId="b" type="grid" gridColumn="1 / 25" gridRow="1 / 6" gridTemplateColumns="1fr 1fr 1fr">
        <Element elementId="x" gridColumn="1 / 2" gridRow="1 / 6"/>
        <Element elementId="y" gridColumn="2 / 3" gridRow="1 / 6"/>
        <Element elementId="z" gridColumn="3 / 4" gridRow="1 / 6"/>
      </Container>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'x', 'kind' => 'table', 'name' => 'X' },
    { 'id' => 'y', 'kind' => 'table', 'name' => 'Y' },
    { 'id' => 'z', 'kind' => 'table', 'name' => 'Z' }
  ] }]
}
check('explicit 3-track band (all filled) lints clean') { lint(three).none? { |x| x.include?('band under-filled') } }

# --- 4. per-kind minimum tile heights (rule f, E1) ---------------------------
# Sigma renders chart/KPI tiles BLANK under ~3-4 grid rows (page render AND
# PNG exports). A kpi-chart under 4 rows / chart under 8 / table under 10 must
# be rejected; tiles at or above their floor lint clean.
short = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Container elementId="band" type="grid" gridColumn="1 / 25" gridRow="1 / 30" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="kpi1" gridColumn="1 / 13" gridRow="1 / 3"/>
        <Element elementId="bar1" gridColumn="13 / 25" gridRow="1 / 6"/>
        <Element elementId="tbl1" gridColumn="1 / 25" gridRow="6 / 12"/>
        <Element elementId="ok1"  gridColumn="1 / 25" gridRow="12 / 29"/>
      </Container>
      <Element elementId="txt1" gridColumn="1 / 25" gridRow="30 / 31"/>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Revenue' },
    { 'id' => 'bar1', 'kind' => 'bar-chart', 'name' => 'By Region' },
    { 'id' => 'tbl1', 'kind' => 'table', 'name' => 'Detail' },
    { 'id' => 'ok1', 'kind' => 'pivot-table', 'name' => 'Matrix' },
    { 'id' => 'txt1', 'kind' => 'text', 'body' => 'note' }
  ] }]
}
sv = lint(short)
check('kpi-chart under 4 rows flagged')  { sv.any? { |x| x.include?('kpi1') && x.include?('below minimum height') } }
check('bar-chart under 8 rows flagged')  { sv.any? { |x| x.include?('bar1') && x.include?('below minimum height') } }
check('table under 10 rows flagged')     { sv.any? { |x| x.include?('tbl1') && x.include?('below minimum height') } }
check('17-row pivot NOT flagged')        { sv.none? { |x| x.include?('ok1') && x.include?('below minimum height') } }
check('1-row text flagged (floor 2)')    { sv.any? { |x| x.include?('txt1') && x.include?('below minimum height') } }

tall = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <Container elementId="band" type="grid" gridColumn="1 / 25" gridRow="1 / 13" gridTemplateColumns="repeat(24, 1fr)">
        <Element elementId="kpi1" gridColumn="1 / 13" gridRow="1 / 5"/>
        <Element elementId="bar1" gridColumn="13 / 25" gridRow="1 / 13"/>
      </Container>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Revenue' },
    { 'id' => 'bar1', 'kind' => 'bar-chart', 'name' => 'By Region' }
  ] }]
}
check('tiles at their floors lint clean (no min-height violations)') do
  lint(tall).none? { |x| x.include?('below minimum height') }
end

puts($failures.zero? ? "\nlayout-lint: all tests passed" : "\nlayout-lint: #{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
