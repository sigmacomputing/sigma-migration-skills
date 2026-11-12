#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/sql_provenance'

class FinalizeArtifactsTest < Minitest::Test
  def test_reused_provenance_uses_readback_and_still_rejects_stale_evidence
    Dir.mktmpdir do |work|
      original = File.join(work, 'dm-spec.json')
      reused = File.join(work, 'dm-spec-reused.json')
      File.write(original, JSON.generate('pages' => [], 'name' => 'Draft'))
      File.write(reused, JSON.generate('pages' => [], 'name' => 'Readback'))
      File.write(File.join(work, 'dm-ids.json'), JSON.generate('dataModelId' => 'model-fixture'))
      SqlProvenance.record_active_spec(work, reused, 'model-fixture')
      File.utime(Time.now + 1, Time.now + 1, reused)
      command = [RbConfig.ruby, File.join(__dir__, 'sql-provenance.rb'), '--workdir', work]
      output, status = Open3.capture2e(*command, '--dm-spec', reused)
      assert status.success?, output
      output, status = Open3.capture2e(*command, '--check')
      assert status.success?, output
      output, status = Open3.capture2e(*command, '--dm-spec', original, '--check')
      assert_equal 3, status.exitstatus, output
      File.write(original, JSON.generate('pages' => [], 'name' => 'Fresh Draft'))
      File.utime(Time.now + 2, Time.now + 2, original)
      output, status = Open3.capture2e(*command, '--check')
      assert status.success?, 'a newer unposted draft must not replace the active model'
      SqlProvenance.record_active_spec(work, original, 'model-fixture')
      output, status = Open3.capture2e(*command, '--check')
      assert_equal 3, status.exitstatus, output
      assert_includes output, 'stale'
      output, status = Open3.capture2e(*command, '--dm-spec', original)
      assert status.success?, output
      File.write(reused, JSON.generate('pages' => [], 'name' => 'Changed'))
      File.utime(Time.now + 3, Time.now + 3, reused)
      output, status = Open3.capture2e(*command, '--check')
      assert status.success?, 'an unused reused-model snapshot must not replace the active model'
      File.write(original, JSON.generate('pages' => [], 'name' => 'Changed Active'))
      output, status = Open3.capture2e(*command, '--check')
      assert_equal 3, status.exitstatus, output
      assert_includes output, 'stale'
    end
  end

  # Field case 2026-10-30: pass 1 bound provenance to the reused DM, then the
  # exit-16 flow PUT a new Custom SQL element through dm-spec.json. The pass-1
  # binding never sees it. Finalize re-derives from the live readback (server
  # ids, so the ledger matches by name) and binds that as the active spec.
  def test_finalize_rederives_provenance_from_the_live_readback
    Dir.mktmpdir do |work|
      sql = 'SELECT region, SUM(amount) FROM orders GROUP BY region'
      sql_el = ->(id, name, statement) { { 'id' => id, 'name' => name, 'source' => { 'kind' => 'sql', 'statement' => statement } } }
      File.write(File.join(work, 'conv-meta.json'), JSON.generate(
        'sqlProvenance' => [{ 'elementId' => 'conv-lod', 'elementName' => 'Revenue LOD Helper',
                              'originType' => 'generated-lod', 'statement' => sql }]
      ))
      File.write(File.join(work, 'dm-ids.json'), JSON.generate('dataModelId' => 'model-fixture'))
      command = [RbConfig.ruby, File.join(__dir__, 'sql-provenance.rb'), '--workdir', work]
      reused = File.join(work, 'dm-spec-reused.json')
      File.write(reused, JSON.generate('pages' => [{ 'elements' => [sql_el.call('srv-1', 'Revenue LOD Helper', sql)] }]))
      SqlProvenance.record_active_spec(work, reused, 'model-fixture')
      output, status = Open3.capture2e(*command, '--dm-spec', reused)
      assert status.success?, output

      final = File.join(work, 'dm-spec-final.json')
      File.write(final, JSON.generate('pages' => [{ 'elements' => [
        sql_el.call('srv-9', 'Revenue LOD Helper', sql),
        sql_el.call('srv-10', 'Residue', 'SELECT secret FROM nowhere')
      ] }]))
      SqlProvenance.record_active_spec(work, final, 'model-fixture')
      output, status = Open3.capture2e(*command, '--dm-spec', final)
      assert_equal 3, status.exitstatus, "exit-16 Custom SQL on the live DM is caught at finalize: #{output}"

      File.write(final, JSON.generate('pages' => [{ 'elements' => [sql_el.call('srv-9', 'Revenue LOD Helper', sql)] }]))
      SqlProvenance.record_active_spec(work, final, 'model-fixture')
      output, status = Open3.capture2e(*command, '--dm-spec', final)
      assert status.success?, "a server-id helper is attributed by ledger name: #{output}"
      output, status = Open3.capture2e(*command, '--check')
      assert status.success?, "later checks follow the live readback: #{output}"
    end

    source = File.read(File.join(__dir__, 'migrate-tableau.rb'))
    finalize = source.split('if opts[:finalize]', 2).last.split('  # Generate the missing action-accounting pair', 2).first
    assert_includes finalize, '"/v2/dataModels/#{state[\'data_model_id\']}/spec"'
    assert_includes finalize, "SqlProvenance.record_active_spec(WORK, _final_dm_path, state['data_model_id'])"
    assert_includes finalize, "sqlp_cmd += ['--dm-spec', _final_dm_path]"
  end

  def test_finalize_generates_empty_action_accounting_but_preserves_existing_files
    source = File.read(File.join(__dir__, 'migrate-tableau.rb'))
    chunk = source.split('  # Generate the missing action-accounting pair', 2).last
                  .split('  # The census-aware hard gate.', 2).first
    chunk = chunk.lines.drop(2).join
    Dir.mktmpdir do |work|
      File.write(File.join(work, 'workbook-content.twb'), '<workbook/>')
      File.write(File.join(work, 'wb-ids.json'), JSON.generate('pages' => []))
      runner = Module.new
      runner.const_set(:WORK, work)
      runner.const_set(:HERE, __dir__)
      runner.define_singleton_method(:run!) do |args, **|
        output, status = Open3.capture2e(*args)
        raise output unless status.success?
      end
      runner.module_eval(chunk)
      ledger = File.join(work, 'action-ledger.json')
      guide = File.join(work, 'POSTPUBLISH_GUIDE.md')
      assert_equal 0, JSON.parse(File.read(ledger))['detectedCount']
      assert File.file?(guide)
      File.write(ledger, 'invalid existing ledger')
      File.write(guide, 'operator notes')
      runner.module_eval(chunk)
      assert_equal 'invalid existing ledger', File.read(ledger)
      assert_equal 'operator notes', File.read(guide)
      File.unlink(ledger)
      runner.module_eval(chunk)
      refute File.exist?(ledger), 'a partial pair must reach validation, not be silently repaired'
      assert_equal 'operator notes', File.read(guide)
    end
  end
end
