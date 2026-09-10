#!/usr/bin/env ruby
# Offline: lib/layout.rb's XML emitters must produce the POST-2026-08-07 tag
# names — <Element> / <Container>, never the legacy <LayoutElement> /
# <GridContainer>.
#
# WHY THIS TEST EXISTS
# --------------------
# lib/layout.rb is a copy of tableau-to-sigma's, carrying a "do not diverge
# this copy" header. When the layout contract renamed the tags, tableau,
# powerbi and quicksight all moved; this copy did not, and stayed wrong for
# ~2.5 weeks.
#
# It never broke a live run, which is exactly why nothing caught it:
# Sigma::CodeRep.document() and .wrap() both canonicalize the layout on the way
# to the wire, so every artifact and every POST came out correct. The emitter
# was wrong, the output was right, and no test looked at the emitter.
#
# That safety net only covers paths that go through the adapter. A script that
# writes document.layout directly, or a human reading an intermediate artifact
# and hand-building a request from it, sees <LayoutElement> and gets a 400.
# So the emitters are pinned here directly, deliberately WITHOUT routing
# through CodeRep — canonicalizing first would test the net, not the emitter.
#
# tools/lint-layout-tags.rb enforces the same rule fleet-wide; this keeps the
# check inside domo's own suite so it survives running the plugin standalone.
#
#   ruby test/test-layout-xml-tags.rb

require_relative '../scripts/lib/layout'

$failures = 0
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end
def ok(cond, msg) eq(!!cond, true, msg) end

LEGACY = /<\/?(?:LayoutElement|GridContainer)\b/

puts 'lib/layout.rb XML emitters — tag names'

el = SigmaLayout.le('el-a', 1, 25, 1, 5)
ok(el.include?('<Element '),  'le() emits <Element>')
ok(!el.match?(LEGACY),        'le() emits no legacy tag')
ok(el.include?('elementId="el-a"'), 'le() carries the elementId')

gc = SigmaLayout.gc('c-1', 1, 25, 1, 8, el)
ok(gc.include?('<Container '),  'gc() opens <Container>')
ok(gc.include?('</Container>'), 'gc() closes </Container>')
ok(!gc.match?(LEGACY),          'gc() emits no legacy tag')
ok(gc.include?(el),             'gc() nests its children verbatim')

page = SigmaLayout.page_xml('pg-1', gc)
ok(page.start_with?('<Page '), 'page_xml() opens <Page>')
ok(!page.match?(LEGACY),       'page_xml() output is free of legacy tags end to end')

# The whole point: a document.layout built straight from these emitters must be
# wire-ready with NO canonicalization step in between.
ok(!SigmaLayout.assemble(page).match?(LEGACY),
   'assemble() output is wire-ready without CodeRep canonicalization') if SigmaLayout.respond_to?(:assemble)

puts($failures.zero? ? "\nALL PASS" : "\n#{$failures} FAILURES")
exit($failures.zero? ? 0 : 1)
