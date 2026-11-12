#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'open3'
require 'rbconfig'
require_relative 'lib/factory_punchlist'

class ReportVerificationFreshnessTest < Minitest::Test
  def test_completion_report_failure_overrides_scope_cuts_and_verifier_green
    Dir.mktmpdir do |work|
      entry = { 'class' => 'scope-cut', 'item' => 'Missing chart', 'reason' => 'not built', 'source_artifact' => 'coverage.json' }
      File.write(File.join(work, 'degradation-ledger.json'), JSON.generate('entries' => [entry], 'counts' => { 'scope-cut' => 1 }))
      File.write(File.join(work, 'verification-result.json'), '{"verdict":"GREEN"}')
      report = { 'verdict' => 'RED', 'checks' => [{ 'name' => 'reconstruction', 'status' => 'FAIL', 'message' => 'Control remains unfinished' }] }
      raw = JSON.generate(report)
      File.write(File.join(work, 'migration-result.json'), raw)
      result = FactoryPunchlist.write(work)
      assert_equal 'RED', result['verdict']
      assert_equal 'PARTIAL', result['ledger_verdict']
      assert_equal Digest::SHA256.hexdigest(raw), result.dig('completion_report', 'sha256')
      assert_equal [entry], result['items'].map { |item| item.reject { |key, _| key == 'reentry' } }
      assert_includes File.read(File.join(work, 'PUNCHLIST.md')), 'Control remains unfinished'
      report['verdict'] = 'GREEN'
      File.write(File.join(work, 'migration-result.json'), JSON.generate(report))
      assert_equal 'RED', FactoryPunchlist.build(work)['verdict'], 'a failed check cannot hide behind a GREEN report headline'
    end
  end

  def test_unreadable_completion_report_is_not_ignored
    Dir.mktmpdir do |work|
      ['{', '{}', '{"verdict":"GREEN","checks":{}}'].each do |raw|
        File.write(File.join(work, 'migration-result.json'), raw)
        result = FactoryPunchlist.write(work)
        assert_equal 'RED', result['verdict']
        assert result.dig('completion_report', 'unreadable')
        refute_includes File.read(File.join(work, 'PUNCHLIST.md')), 'Nothing was cut, waived, escaped, or left unresolved'
      end
    end
  end

  def test_verifier_failure_overrides_a_clean_ledger_without_changing_its_entries
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'degradation-ledger.json'), JSON.generate('entries' => [], 'counts' => {}))
      clean = FactoryPunchlist.write(work)
      assert_equal 'GREEN', clean['verdict']
      File.write(File.join(work, 'verification-result.json'), JSON.generate(
        'verdict' => 'RED', 'divergences' => [{ 'severity' => 'number', 'element' => 'Revenue',
          'description' => 'Value differs from the source', 'suggested_fix' => 'Restore the source filter' }]
      ))
      failed = FactoryPunchlist.write(work)
      assert_equal 'RED', failed['verdict']
      assert_equal 'GREEN', failed['ledger_verdict']
      assert_empty failed['items']
      assert_equal [], JSON.parse(File.read(File.join(work, 'degradation-ledger.json')))['entries']
      markdown = File.read(File.join(work, 'PUNCHLIST.md'))
      assert_includes markdown, 'Value differs from the source'
      assert_includes markdown, 'Restore the source filter'
      refute_includes markdown, 'Nothing was cut, waived, escaped, or left unresolved'
    end
  end

  def test_verification_never_upgrades_scope_cuts_or_quality_degradations
    Dir.mktmpdir do |work|
      entry = { 'class' => 'scope-cut', 'item' => 'Missing chart', 'reason' => 'not built', 'source_artifact' => 'coverage.json' }
      File.write(File.join(work, 'degradation-ledger.json'), JSON.generate('entries' => [entry], 'counts' => { 'scope-cut' => 1 }))
      %w[GREEN YELLOW RED].zip(%w[PARTIAL PARTIAL+YELLOW RED]).each do |verdict, expected|
        File.write(File.join(work, 'verification-result.json'), JSON.generate('verdict' => verdict))
        assert_equal expected, FactoryPunchlist.build(work)['verdict']
      end
    end
  end

  def test_completion_cannot_use_red_verification_as_a_green_countersignature
    source = File.read(File.join(__dir__, 'verify-complete.rb'), encoding: 'UTF-8')
    chunk = source.split("countersign_evidence =", 2).last.split("factory_green =", 2).first
    Dir.mktmpdir do |work|
      %w[RED YELLOW].each do |verdict|
        File.write(File.join(work, 'verification-result.json'), JSON.generate('verdict' => verdict))
        context = binding
        context.local_variable_set(:wd, work)
        context.local_variable_set(:pf, { 'visual_verdict' => 'pass', 'visual_notes' => 'VERIFIER: prior pass' })
        context.local_variable_set(:derived_verdict, 'GREEN')
        context.local_variable_set(:contradictions, [])
        eval("countersign_evidence =#{chunk}", context, File.join(__dir__, 'verify-complete.rb'))
        assert context.local_variable_get(:contradictions).any? { |item| item.include?('verification-result.json') && item.include?(verdict) }
      end
    end
  end

  def test_finalization_does_not_mutate_the_verified_workbook_after_reporting
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
    finalization = source.split('# Refresh source accounting from the FINAL built/readback', 2).last
                         .split("puts '================ RESULT ================'", 2).first
    refute_includes finalization, '--apply-pivot-totals'
    refute_includes finalization, 'pivot-totals-ship'
  end

  def test_render_health_is_measured_from_current_image_not_a_stale_similarity_record
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
    definition = source.match(/^def refresh_render_health\(work\).*?^end$/m)[0]
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'visual-similarity.json'), JSON.generate('render_health' => { 'status' => 'PASS' }))
      runner = Object.new
      runner.singleton_class.class_eval(definition)
      assert_equal false, runner.refresh_render_health(work)[0], 'a missing current image cannot inherit old health'
      runner.singleton_class.const_set(:HERE, __dir__)
      runner.define_singleton_method(:run!) do |command, **|
        raise 'wrong current image' unless command[2] == File.join(work, 'sigma-render.png')
        File.write(File.join(work, 'render-health.json'), JSON.generate('status' => 'FAIL'))
        ['', Struct.new(:success?, :exitstatus).new(false, 1)]
      end
      File.write(File.join(work, 'sigma-render.png'), 'synthetic changed image')
      assert_equal false, runner.refresh_render_health(work)[0], 'a newly failed image must replace old PASS health'
      assert_equal 'FAIL', JSON.parse(File.read(File.join(work, 'render-health.json')))['status']
    end
  end

  def test_render_health_falls_back_to_the_recorded_screenshot_when_sigma_render_is_absent
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'), encoding: 'UTF-8')
    definition = source.match(/^def refresh_render_health\(work\).*?^end$/m)[0]
    Dir.mktmpdir do |work|
      runner = Object.new
      runner.singleton_class.class_eval(definition)
      runner.singleton_class.const_set(:HERE, __dir__)
      measured = []
      runner.define_singleton_method(:run!) do |command, **|
        measured << command[2]
        ['', Struct.new(:success?, :exitstatus).new(true, 0)]
      end
      shot = File.join(work, 'rcf-pass-3.png')
      File.write(shot, 'synthetic image')
      File.write(File.join(work, 'parity-final.json'), JSON.generate('screenshot_path' => shot))
      ok, note = runner.refresh_render_health(work)
      assert_equal true, ok
      assert_equal [shot], measured
      assert_includes note, 'rcf-pass-3.png'
      # sigma-render.png still wins when present.
      measured.clear
      File.write(File.join(work, 'sigma-render.png'), 'synthetic image')
      runner.refresh_render_health(work)
      assert_equal [File.join(work, 'sigma-render.png')], measured
      # A screenshot_path naming a missing file (or an empty one) measures nothing.
      File.delete(File.join(work, 'sigma-render.png'))
      ['', File.join(work, 'gone.png')].each do |bad|
        measured.clear
        File.write(File.join(work, 'parity-final.json'), JSON.generate('screenshot_path' => bad))
        assert_equal false, runner.refresh_render_health(work)[0]
        assert_empty measured
      end
    end
  end

  def test_malformed_verification_is_reported_as_unverified_not_silently_ignored
    Dir.mktmpdir do |work|
      ['{', '{}', '{"verdict":"GREEN","divergences":{}}'].each do |raw|
        File.write(File.join(work, 'verification-result.json'), raw)
        result = FactoryPunchlist.write(work)
        assert_equal 'RED', result['verdict']
        assert_equal true, result['verification']['unreadable']
      end
    end
  end

  def test_bom_and_cosmetic_residue_are_supported_but_number_and_structure_override_green
    Dir.mktmpdir do |work|
      %w[number structural cosmetic].zip(%w[RED YELLOW GREEN]).each do |severity, expected|
        raw = "\uFEFF" + JSON.generate('verdict' => 'GREEN', 'divergences' => [
          { 'severity' => severity, 'element' => 'Panel', 'description' => 'Synthetic finding' }
        ])
        File.write(File.join(work, 'verification-result.json'), raw)
        result = FactoryPunchlist.write(work)
        assert_equal expected, result['verdict']
        assert_equal Digest::SHA256.hexdigest(raw), result['verification']['sha256']
        if severity == 'cosmetic'
          assert_includes File.read(File.join(work, 'PUNCHLIST.md')), '- [x] [cosmetic]'
        end
      end
      File.binwrite(File.join(work, 'verification-result.json'), "{\"verdict\":\"\xff\"}".b)
      assert FactoryPunchlist.read_verification(work)['unreadable']
    end
  end

  def test_failed_rebuild_archives_previous_reports_instead_of_leaving_them_current
    Dir.mktmpdir do |work|
      ledger = File.join(work, 'degradation-ledger.json')
      File.write(ledger, JSON.generate('entries' => [], 'counts' => {}))
      FactoryPunchlist.write(work)
      prior = File.binread(File.join(work, 'PUNCHLIST.md'))
      File.write(ledger, '{')
      assert_raises(JSON::ParserError) { FactoryPunchlist.write(work) }
      refute File.exist?(File.join(work, 'PUNCHLIST.md'))
      refute File.exist?(File.join(work, 'punchlist.json'))
      archived = Dir.glob(File.join(work, 'report-history', '*', 'PUNCHLIST.md'))
      assert_equal 1, archived.size
      assert_equal prior, File.binread(archived.first)
    end
  end
end
