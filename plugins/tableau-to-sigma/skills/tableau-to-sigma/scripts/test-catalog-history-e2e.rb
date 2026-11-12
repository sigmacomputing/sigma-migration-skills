#!/usr/bin/env ruby
# frozen_string_literal: true
# End-to-end: the platform-difference catalog GAINS an entry between grading
# and recording (live 2026-11-09: adding pivot-row-height-fixed forced fresh
# re-grades of Complex Pivot). The grade must record as graded — gaps kept
# exactly, never re-mapped onto the new id — with an optional re-grade offered,
# and the Python twin must accept it too. A catalog that REMOVED or CHANGED an
# entry the grade's catalog had, or a sha the history does not know, refuses.
#
# Runs record-visual-check.rb from a throwaway copy of the skill tree, because
# the recorder only ever reads the SHIPPED ../refs catalog (no --catalog).
#
# Usage:  ruby scripts/test-catalog-history-e2e.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require_relative 'lib/blind_fixture'
require_relative 'lib/blind_grade'

HERE = __dir__
SHIPPED = JSON.parse(File.read(File.expand_path('../refs/sigma-platform-differences.json', HERE)))
NEW_ID = 'pivot-row-height-fixed'
CAT_A = SHIPPED.merge('entries' => SHIPPED['entries'].reject { |e| e['id'] == NEW_ID }) # before the addition
CAT_B = SHIPPED                                                                         # after it
abort 'FATAL: shipped catalog lacks pivot-row-height-fixed (fixture premise)' if CAT_A['entries'].size == CAT_B['entries'].size

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A minimal skill tree: scripts/record-visual-check.rb + its libs, refs/catalog.
def make_tree(root)
  FileUtils.mkdir_p(File.join(root, 'scripts', 'lib'))
  FileUtils.mkdir_p(File.join(root, 'refs'))
  FileUtils.cp(File.join(HERE, 'record-visual-check.rb'), File.join(root, 'scripts'))
  %w[blind_grade.rb code_rep.rb cli_encoding.rb ruby_compat.rb blind_grade_v2.py].each do |f|
    FileUtils.cp(File.join(HERE, 'lib', f), File.join(root, 'scripts', 'lib'))
  end
end

# Write the tree's catalog; `history` lists every catalog (oldest first) the
# history file records — what tools/gen-catalog-history.rb would write.
def ship_catalog(root, catalog, history)
  path = File.join(root, 'refs', 'sigma-platform-differences.json')
  File.write(path, JSON.pretty_generate(catalog))
  recs = history.map do |c|
    parsed = BlindGrade.parse_catalog_bytes(JSON.pretty_generate(c))
    raise parsed['errors'].join('; ') unless parsed['errors'].empty?
    { 'sha256' => parsed['sha256'], 'entries' => parsed['entry_hashes'] }
  end
  File.write(BlindGrade.history_path_for(path), JSON.pretty_generate('schema' => BlindGrade::HISTORY_SCHEMA, 'catalogs' => recs))
  path
end

def sha_of(catalog)
  Digest::SHA256.hexdigest(JSON.pretty_generate(catalog))
end

PLATFORM_GAP = { 'tile' => 'Region Sales', 'dimension' => 'labels_legible', 'description' => 'typeface differs',
                 'severity' => 'minor', 'class' => 'font-family' }.freeze
# Graded BEFORE pivot-row-height-fixed existed: the grader filed taller pivot
# rows as a minor FIXABLE gap. It must stay exactly that (never re-mapped).
FIXABLE_GAP = { 'tile' => 'Complex Pivot', 'dimension' => 'composition_match',
                'description' => 'pivot rows are taller than the source', 'severity' => 'minor', 'class' => 'fixable' }.freeze

# Grade against catalog A, then ship `later` (+ history) and record.
# → [out, err, status, parity-final, visual-residuals|nil, workdir-relative grade path, tree root]
def grade_then_record(later, history, args: [])
  Dir.mktmpdir('cat-hist-e2e') do |root|
    make_tree(root)
    cat_a = ship_catalog(root, CAT_A, [CAT_A])
    dir = File.join(root, 'work')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'parity-final.json'), JSON.pretty_generate('status' => 'PASS', 'charts_total' => 2, 'charts_pass' => 2))
    BlindFixture.install_v2(dir, catalog_path: cat_a, score: 85, gaps: [PLATFORM_GAP, FIXABLE_GAP])
    File.write(File.join(dir, 'fidelity-ledger.json'), JSON.generate(
      'workbook_id' => 'wb', 'page_id' => 'p', 'pass' => 1, 'max_passes' => 5,
      'renders' => [{ 'pass' => 1, 'path' => 'sigma-render.png' }], 'entries' => []
    ))
    ship_catalog(root, later, history) # the catalog changes AFTER grading
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, err, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, File.join(root, 'scripts', 'record-visual-check.rb'),
                                  '--workdir', dir, '--agent-vision', 'true',
                                  '--blind-grade', File.join(dir, 'blind-grade.json'), *args) # no --screenshot: inferred
    vr_path = File.join(dir, 'visual-residuals.json')
    py = Open3.capture3('python3', '-c', <<~PY, File.join(root, 'scripts', 'lib'), File.join(dir, 'blind-grade.json'))
      import json, sys
      sys.path.insert(0, sys.argv[1])
      import blind_grade_v2 as bg
      from pathlib import Path
      r = bg.evaluate_grade_set(Path(sys.argv[2]))
      d = r.get("decision") or {}
      print(json.dumps({"errors": r["errors"], "faithful": d.get("faithful"),
                        "residuals": d.get("residuals"), "platform": d.get("platform_differences")}))
    PY
    yield out, err, st, JSON.parse(File.read(File.join(dir, 'parity-final.json'))),
          File.file?(vr_path) ? JSON.parse(File.read(vr_path)) : nil, py
  end
end

puts '== catalog gains an entry between grading and recording =='
grade_then_record(CAT_B, [CAT_A, CAT_B]) do |out, err, st, pf, vr, py|
  check(st.success?, "record exits 0 (#{st.exitstatus}) #{err.lines.grep(/REFUSED|mismatch/).first(2).join(' ').strip}")
  check(pf['visual_verdict'] == 'pass' && pf.dig('blind_grade', 'faithful') == true, 'verdict computed PASS from the ancestor grade')
  check(pf.dig('blind_grade', 'catalog_sha256') == sha_of(CAT_B), 'stamp records the shipped catalog it was validated against')
  lin = pf.dig('blind_grade', 'catalog_lineage') || {}
  check(lin['graded_catalog_sha256'] == [sha_of(CAT_A)] && lin['new_ids'] == [NEW_ID],
        'stamp names the lineage: graded catalog A, new id pivot-row-height-fixed')
  check(lin['regrade'].to_s.start_with?('optional'), 'the re-grade is optional, never required')
  check(out.include?('graded against an earlier catalog') && out.include?(NEW_ID) && out.include?('Optional: re-run'),
        'output offers an optional re-grade naming the new entry')
  check(vr && vr['residuals'] == [FIXABLE_GAP] && vr['platform_differences'] == [PLATFORM_GAP] && vr['fixable_major'] == [],
        'gaps kept exactly as graded: the fixable row-height gap is NOT re-mapped onto the new catalog id')
  check(vr && vr['catalog_lineage'] == lin, 'visual-residuals.json carries the same lineage')
  check(pf['screenshot_path'] == 'sigma-render.png' && out.include?('--screenshot not given'),
        '--screenshot inferred from the ledger\'s latest render (and stamped)')
  py_out, py_err, py_st = py
  pj = (JSON.parse(py_out) rescue {})
  check(py_st.success? && pj['errors'] == [] && pj['faithful'] == true && pj['residuals'] == [FIXABLE_GAP],
        "Python twin accepts the ancestor grade as graded #{py_err.lines.last}")
end

puts '== refusals =='
changed = CAT_B.merge('entries' => CAT_B['entries'].map { |e| e['id'] == 'font-family' ? e.merge('description' => "#{e['description']} (reworded)") : e })
grade_then_record(changed, [CAT_A, changed]) do |_out, err, st, pf, vr, py|
  check(st.exitstatus == 2 && err.include?('font-family was CHANGED') && !pf.key?('visual_verdict') && vr.nil?,
        'catalog CHANGED an entry since grading → refused exit 2, nothing written')
  check((JSON.parse(py[0])['errors'] rescue []).any? { |e| e.include?('CHANGED') }, 'Python twin refuses the changed-entry grade')
end
removed = CAT_B.merge('entries' => CAT_B['entries'].reject { |e| e['id'] == 'nav-button-style' })
grade_then_record(removed, [CAT_A, removed]) do |_out, err, st, pf, _vr, py|
  check(st.exitstatus == 2 && err.include?('nav-button-style was REMOVED') && !pf.key?('visual_verdict'),
        'catalog REMOVED an entry since grading → refused exit 2')
  check((JSON.parse(py[0])['errors'] rescue []).any? { |e| e.include?('REMOVED') }, 'Python twin refuses the removed-entry grade')
end
grade_then_record(CAT_B, [CAT_B]) do |_out, err, st, pf, _vr, py|
  check(st.exitstatus == 2 && err.include?('unknown catalog') && !pf.key?('visual_verdict'),
        'grade sha not in the history (unknown) → refused exit 2')
  check((JSON.parse(py[0])['errors'] rescue []).any? { |e| e.include?('unknown catalog') }, 'Python twin refuses the unknown sha')
end
grade_then_record(CAT_A, [CAT_A]) do |out, _err, st, pf, _vr, _py|
  check(st.success? && pf['visual_verdict'] == 'pass' && !pf['blind_grade'].key?('catalog_lineage') &&
        !out.include?('earlier catalog'), 'unchanged catalog: current sha accepted, no lineage stamped')
end

puts($fails.empty? ? 'ALL PASS — catalog history e2e' : "#{$fails.size} FAILURE(S)")
exit($fails.empty? ? 0 : 1)
