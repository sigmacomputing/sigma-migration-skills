# frozen_string_literal: true
#
# blind_fixture.rb — TEST-ONLY helper (no production code path requires this).
#
# Gate 8b now refuses a self-attested visual PASS: parity-final.json must carry
# `blind_grade` metadata that is sha256-bound to a blind-grade.json + the two
# image files on disk (PLAN-v3 PR-9). Every gate test that stages a "green"
# workdir therefore needs a minimal VALID blind-grade fixture — this builds one
# with REAL computed hashes so the gate's recompute check passes.
#
#   require_relative 'lib/blind_fixture'
#   BlindFixture.install(dir)              # after parity-final.json + render exist
#
# The fixture reuses <dir>/sigma-render.png when the test already wrote one
# (hashes are computed from whatever bytes are there) and writes a tiny
# source-dashboard.png at the workdir ROOT — deliberately NOT under views/ or
# dashboards/, so it never arms gate 13 (anchors) or gate 14 (similarity).

require 'json'
require 'digest'

module BlindFixture
  KEYS = %w[element_titles_hidden palette_match composition_match
            chart_shapes_match labels_legible numbers_formatted].freeze

  DEFAULT_TILES = [
    { 'position' => 'r1c1', 'source_family' => 'kpi',  'target_family' => 'kpi' },
    { 'position' => 'r2c1', 'source_family' => 'line', 'target_family' => 'line' }
  ].freeze

  module_function

  def png_bytes(seed)
    "\x89PNG\r\n\x1a\n".b + (seed.to_s.b * 6000)
  end

  # Writes source-dashboard.png (root), blind-grade.json, and (by default)
  # stamps `blind_grade` metadata onto an existing parity-final.json exactly as
  # record-visual-check.rb --blind-grade would. Returns the grade Hash.
  def install(dir, verdict: 'pass', per_tile: DEFAULT_TILES, stamp: true)
    src = File.join(dir, 'source-dashboard.png')
    tgt = File.join(dir, 'sigma-render.png')
    File.binwrite(src, png_bytes('S')) unless File.exist?(src)
    File.binwrite(tgt, png_bytes('T')) unless File.exist?(tgt)
    grade = {
      'schema'        => 'blind-grade/v1',
      'source_png'    => src,
      'target_png'    => tgt,
      'source_sha256' => Digest::SHA256.file(src).hexdigest,
      'target_sha256' => Digest::SHA256.file(tgt).hexdigest,
      'dimensions'    => KEYS.map { |k| [k, { 'verdict' => verdict == 'pass' ? 'pass' : (k == 'chart_shapes_match' ? 'fail' : 'pass'), 'evidence' => 'fixture' }] }.to_h,
      'per_tile'      => per_tile,
      'verdict'       => verdict,
      'top_gaps'      => verdict == 'pass' ? [] : ['fixture gap']
    }
    File.write(File.join(dir, 'blind-grade.json'), JSON.pretty_generate(grade))
    pf_path = File.join(dir, 'parity-final.json')
    if stamp && File.exist?(pf_path)
      pf = JSON.parse(File.read(pf_path))
      pf['blind_grade'] = {
        'path'           => 'blind-grade.json',
        'source_sha256'  => grade['source_sha256'],
        'target_sha256'  => grade['target_sha256'],
        'verdict'        => grade['verdict'],
        'dimensions'     => grade['dimensions'].map { |k, v| [k, v['verdict']] }.to_h,
        'per_tile_count' => per_tile.length,
        'top_gaps'       => grade['top_gaps'],
        'cross_check'    => { 'target' => 'skipped (no mechanical census artifact)',
                              'source' => 'skipped (no mechanical census artifact)' },
        'recorded_at'    => '2026-07-18T00:00:00Z'
      }
      File.write(pf_path, JSON.pretty_generate(pf))
    end
    grade
  end
end
