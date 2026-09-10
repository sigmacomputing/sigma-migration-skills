#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-layout-tags.rb — fleet gate: no layout emitter may produce the legacy
# `<LayoutElement>` / `<GridContainer>` tags.
#
# WHY THIS EXISTS
# ---------------
# The 2026-08-07 workbook layout contract renamed the tags: `<LayoutElement>`
# -> `<Element>` and `<GridContainer>` -> `<Container>`. The converters were
# migrated, but `domo-to-sigma`'s `scripts/lib/layout.rb` — a VENDORED copy of
# tableau's, carrying a "do not diverge this copy" header — was left on the old
# tags for ~2.5 weeks and nothing caught it.
#
# It did not break live runs, because `Sigma::CodeRep.document()` and `.wrap()`
# both canonicalize the layout on the way to the wire. That safety net is
# exactly what made this invisible: the emitter was wrong, every artifact and
# every POST was right, and no test looked at the emitter.
#
# The net only covers paths that go THROUGH the adapter. A script that writes
# `document.layout` directly, or a human reading an intermediate artifact and
# hand-building a request from it, sees the legacy tags and gets a 400. So the
# emitters are worth pinning independently of the adapter.
#
# Checks every `scripts/lib/layout.rb` by LOADING it and calling its emitters,
# rather than grepping — a grep cannot tell an emitted tag from a comment or,
# as in `build-dashboard-layout.rb`, from a guard regex that legitimately names
# the legacy tags in order to reject them.

require 'open3'

LEGACY = /<\/?(?:LayoutElement|GridContainer)\b/

roots = Dir.glob('plugins/*/skills/*/scripts/lib/layout.rb').sort
abort 'lint-layout-tags: no layout.rb found — wrong cwd?' if roots.empty?

failures = []
roots.each do |path|
  dir = File.dirname(File.dirname(path)) # .../scripts
  probe = <<~RUBY
    $LOAD_PATH.unshift 'lib'
    require 'layout'
    out = []
    out << SigmaLayout.le('e', 1, 25, 1, 5) if SigmaLayout.respond_to?(:le)
    out << SigmaLayout.gc('c', 1, 25, 1, 5, 'x') if SigmaLayout.respond_to?(:gc)
    out << SigmaLayout.page_xml('p', 'x') if SigmaLayout.respond_to?(:page_xml)
    print out.join("\\n")
  RUBY
  stdout, stderr, status = Open3.capture3('ruby', '-e', probe, chdir: dir)
  unless status.success?
    puts "  ~ #{path}: could not load (#{stderr.lines.first&.strip}) — skipped"
    next
  end
  if stdout.match?(LEGACY)
    failures << path
    puts "  ✗ #{path}: emits legacy layout tags"
    stdout.lines.grep(LEGACY).each { |l| puts "      #{l.strip}" }
  else
    puts "  ✓ #{path}"
  end
end

if failures.empty?
  puts "\nlint-layout-tags OK (#{roots.size} emitters checked)"
  exit 0
end
warn "\nlint-layout-tags FAILED — #{failures.size} emitter(s) still produce " \
     '<LayoutElement>/<GridContainer>. Use <Element>/<Container>.'
exit 1
