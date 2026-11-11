#!/usr/bin/env ruby
# frozen_string_literal: true

# Pins the v1 (all-six-pass) path of record-visual-check.rb in EVERY plugin that
# vendors it (shared/manifest.json). Each copy runs from its own location so it
# uses its own vendored lib/blind_grade.rb. A plugin that never adopted
# blind-grade/v2 must behave exactly as before.

require 'json'
require 'digest'
require 'open3'
require 'rbconfig'
require 'tmpdir'

ROOT = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(ROOT, 'shared/manifest.json')))
entry = Array(manifest['shared']).find { |e| e['canonical'] == 'shared/scripts/record-visual-check.rb' }
abort 'FATAL: record-visual-check.rb not found in shared/manifest.json' unless entry
copies = entry['targets'].map { |t| File.join(ROOT, t) }

KEYS = %w[element_titles_hidden palette_match composition_match
          chart_shapes_match labels_legible numbers_formatted].freeze
CL = KEYS.map { |k| "#{k}=pass" }.join(',')

$fails = []
def ok(msg, cond)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def v1_grade(dir, fail_dim: nil)
  src = File.join(dir, 'source-dashboard.png')
  tgt = File.join(dir, 'sigma-render.png')
  File.binwrite(src, "\x89PNG\r\n\x1a\n".b + ('S' * 6000))
  File.binwrite(tgt, "\x89PNG\r\n\x1a\n".b + ('T' * 6000))
  grade = {
    'schema' => 'blind-grade/v1', 'source_png' => src, 'target_png' => tgt,
    'source_sha256' => Digest::SHA256.file(src).hexdigest,
    'target_sha256' => Digest::SHA256.file(tgt).hexdigest,
    'dimensions' => KEYS.map { |k| [k, { 'verdict' => k == fail_dim ? 'fail' : 'pass', 'evidence' => 'fixture' }] }.to_h,
    'per_tile' => [{ 'position' => 'r1c1', 'source_family' => 'kpi', 'target_family' => 'kpi' }],
    'verdict' => fail_dim ? 'fail' : 'pass',
    'top_gaps' => fail_dim ? ['fixture gap'] : []
  }
  File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(grade))
end

def run(copy, fail_dim: nil)
  Dir.mktmpdir('rvc-shared') do |dir|
    File.write(File.join(dir, 'parity-final.json'), JSON.generate('status' => 'PASS'))
    v1_grade(dir, fail_dim: fail_dim)
    # Test harness: runs a fixed script from this skill with literal arguments and temp-dir paths.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    _o, e, st = Open3.capture3({ 'AGENT_VISION' => nil }, RbConfig.ruby, copy, '--workdir', dir,
                               '--verdict', 'pass', '--agent-vision', 'true', '--notes', 'ok',
                               '--checklist', CL, '--blind-grade', File.join(dir, 'blind-grade.json'))
    [e, st, JSON.parse(File.read(File.join(dir, 'parity-final.json'))),
     File.exist?(File.join(dir, 'visual-residuals.json'))]
  end
end

copies.each do |copy|
  label = copy.sub("#{ROOT}/plugins/", '').split('/scripts/').first
  unless File.file?(copy)
    ok("#{label}: copy exists", false)
    next
  end
  _e, st, pf, residuals = run(copy)
  ok("#{label}: v1 all-six-pass → exit 0, visual_verdict pass",
     st.exitstatus == 0 && pf['visual_verdict'] == 'pass')
  ok("#{label}: v1 stamp has no v2 fields and writes no visual-residuals.json",
     !pf['blind_grade'].key?('schema') && !pf['blind_grade'].key?('grades') && !residuals)
  _e, st, pf, _r = run(copy, fail_dim: 'palette_match')
  ok("#{label}: v1 one failing dimension + --verdict pass → exit 2, nothing written",
     st.exitstatus == 2 && !pf.key?('visual_verdict'))
end

puts
if $fails.empty?
  puts "ALL PASS — v1 record-visual-check pinned across #{copies.length} plugin copies"
  exit 0
end
puts "FAILURES (#{$fails.length}):"
$fails.each { |f| puts "  - #{f}" }
exit 1
