#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for the post-lightdash-dm.rb readback gate and lookup (no API calls).
#
#   ruby test/test-post-lightdash-dm.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'support/fake_run'
require_relative '../scripts/post-lightdash-dm'
require_relative '../scripts/convert-dm'

class PostLightdashDmTest < Minitest::Test
  P = PostLightdashDm
  FIXTURE = File.expand_path('../fixtures/jaffle-orders', __dir__)

  def envelope
    @envelope ||= begin
      lm = LightdashModel.load(FIXTURE)
      LightdashDm.build(lm, 'orders', connection_id: 'c')[0]
    end
  end

  def authored
    envelope['sigmaDataModel']
  end

  # A readback that renames ids the way the server does.
  def live_copy
    live = JSON.parse(JSON.generate(authored))
    P.elements_of(live).each_with_index do |el, i|
      el['id'] = "srv#{i}"
      el['columns'].each_with_index { |c, j| c['id'] = "srv#{i}/c#{j}" }
      (el['metrics'] || []).each_with_index { |m, j| m['id'] = "srv#{i}/m#{j}" }
    end
    live
  end

  def test_unwrap_accepts_envelope_and_bare_spec
    assert_equal authored, P.unwrap_dm_spec(envelope)
    assert_equal authored, P.unwrap_dm_spec(authored)
  end

  def test_gate_passes_on_matching_readback
    assert_empty P.readback_mismatches(authored, live_copy, stats: envelope['stats'])
  end

  def test_gate_fails_on_dropped_column
    live = live_copy
    P.elements_of(live)[0]['columns'].pop
    problems = P.readback_mismatches(authored, live)
    assert_equal 2, problems.length
    assert_match(/el-orders: columns authored 16, live 15/, problems[0])
    assert_match(/el-orders: column ".*" missing from readback/, problems[1])
  end

  def test_gate_pairs_by_name_not_position
    live = live_copy
    P.elements_of(live).reverse!                       # element order is not promised
    P.elements_of(live).each { |el| el['columns'].reverse! }
    assert_empty P.readback_mismatches(authored, live, stats: envelope['stats'])
    lookup = P.lookup_from_readback(live, authored, data_model_id: 'dm1')
    ex = lookup['explore-orders']
    live_ex = P.elements_of(live).find { |e| e['name'] == ex['name'] }
    assert_equal live_ex['id'], ex['elementId']
    first = ex['columns'][0]
    live_col = live_ex['columns'].find { |c| c['name'] == first['name'] }
    assert_equal live_col['id'], first['liveId'], 'column ids follow the name, not the position'
  end

  def test_gate_catches_a_renamed_column_of_the_same_count
    live = live_copy
    P.elements_of(live)[0]['columns'][2]['name'] = 'Renamed By Server'
    problems = P.readback_mismatches(authored, live)
    assert_equal 1, problems.length
    assert_match(/column ".*" missing from readback/, problems[0])
  end

  def test_gate_fails_on_error_typed_live_columns
    live = live_copy
    P.elements_of(live)[0]['columns'][0]['type'] = 'error'
    assert_match(/is error-typed in the readback/, P.readback_mismatches(authored, live).join)
  end

  def test_reuse_mode_tolerates_extra_live_items_but_not_missing_ones
    live = live_copy
    P.elements_of(live)[0]['columns'] << { 'id' => 'extra', 'name' => 'Inherited Extra' }
    assert_match(/columns authored 16, live 17/, P.readback_mismatches(authored, live).join)
    assert_empty P.readback_mismatches(authored, live, exact: false)
    gone = P.elements_of(authored)[0]['columns'][0]['name']
    P.elements_of(live)[0]['columns'].reject! { |c| c['name'] == gone }
    assert_match(/missing from readback/, P.readback_mismatches(authored, live, exact: false).join)
  end

  # ---- CLI paths against the in-memory fake Sigma (test/support/fake_net.rb) ----------------
  SCRIPT = File.expand_path('../scripts/post-lightdash-dm.rb', __dir__)

  def cli(dir, mode: nil, env: {})
    File.write(File.join(dir, 'dm.json'), JSON.generate(envelope))
    args = ['--spec', File.join(dir, 'dm.json'), '--out', File.join(dir, 'dm-elements.json')]
    if mode
      File.write(File.join(dir, 'dm-mode.json'), JSON.generate(mode))
      args += ['--mode', File.join(dir, 'dm-mode.json')]
    end
    Open3.capture3(FakeRun.env(dir, extra: env), RbConfig.ruby, SCRIPT, *args)
  end

  def test_cli_create_posts_then_reads_back_and_writes_the_lookup
    Dir.mktmpdir do |dir|
      _o, err, st = cli(dir)
      assert_equal 0, st.exitstatus, err
      assert_match(/posted data model dm-1; readback verified/, err)
      assert_equal 1, FakeRun.count(dir, 'POST', '/v2/dataModels/spec')
      assert_equal 'dm-1', JSON.parse(File.read(File.join(dir, 'dm-elements.json'), encoding: 'UTF-8'))['orders']['dataModelId']
    end
  end

  def test_cli_reuse_writes_nothing_and_builds_the_lookup_from_the_existing_dm
    Dir.mktmpdir do |dir|
      FakeRun.seed_dms(dir, [{ 'id' => 'dm-9', 'name' => 'Existing', 'spec' => live_copy }])
      _o, err, st = cli(dir, mode: { 'mode' => 'reuse', 'dataModelId' => 'dm-9' })
      assert_equal 0, st.exitstatus, err
      assert_match(/reused \(no write\)/, err)
      assert_equal 0, FakeRun.count(dir, 'POST', '/v2/dataModels'), 'no POST'
      assert_equal 0, FakeRun.count(dir, 'PUT', '/v2/dataModels'), 'no PUT'
      lookup = JSON.parse(File.read(File.join(dir, 'dm-elements.json'), encoding: 'UTF-8'))
      assert_equal 'dm-9', lookup['orders']['dataModelId']
      assert_equal 'srv0', lookup['orders']['elementId']
    end
  end

  def test_cli_reuse_of_a_dm_missing_authored_columns_fails_the_gate
    Dir.mktmpdir do |dir|
      live = live_copy
      P.elements_of(live)[0]['columns'].pop
      FakeRun.seed_dms(dir, [{ 'id' => 'dm-9', 'name' => 'Existing', 'spec' => live }])
      _o, err, st = cli(dir, mode: { 'mode' => 'reuse', 'dataModelId' => 'dm-9' })
      assert_equal 1, st.exitstatus
      assert_match(/READBACK GATE FAILED for data model dm-9/, err)
      assert File.file?(File.join(dir, 'dm-elements.json')), 'lookup still written for diagnosis'
    end
  end

  def test_cli_extend_puts_the_spec_into_the_named_dm
    Dir.mktmpdir do |dir|
      FakeRun.seed_dms(dir, [{ 'id' => 'dm-3', 'name' => 'Old', 'spec' => live_copy }])
      _o, err, st = cli(dir, mode: { 'mode' => 'extend', 'dataModelId' => 'dm-3' })
      assert_equal 0, st.exitstatus, err
      assert_match(/extended data model dm-3/, err)
      assert_equal 1, FakeRun.count(dir, 'PUT', '/v2/dataModels/dm-3/spec')
      assert_equal 0, FakeRun.count(dir, 'POST', '/v2/dataModels')
    end
  end

  def test_cli_readback_mismatch_exits_1_after_posting
    Dir.mktmpdir do |dir|
      _o, err, st = cli(dir, env: { 'FAKE_DROP_COLUMN' => '1' })
      assert_equal 1, st.exitstatus, err
      assert_match(/READBACK GATE FAILED for data model dm-1 \(posted\)/, err)
      assert_match(/columns authored 16, live 15/, err)
    end
  end

  def test_gate_fails_on_dropped_metric_and_element
    live = live_copy
    P.elements_of(live).last['metrics'].shift
    assert_match(/metrics authored 13, live 12/, P.readback_mismatches(authored, live).first)
    live = live_copy
    P.elements_of(live).pop
    problems = P.readback_mismatches(authored, live)
    assert_match(/element count: authored 4, live 3/, problems.first)
    assert(problems.any? { |p| p.include?('missing from readback') })
  end

  def test_gate_cross_checks_envelope_stats
    problems = P.readback_mismatches(authored, live_copy, stats: envelope['stats'].merge('metrics' => 99))
    assert_equal ['envelope stats.metrics is 99, spec has 13'], problems
  end

  def test_lookup_maps_authored_to_live_ids
    lookup = P.lookup_from_readback(live_copy, authored, data_model_id: 'dm1')
    assert_equal %w[orders customers payments explore-orders], lookup.keys
    ex = lookup['explore-orders']
    assert_equal 'srv3', ex['elementId']
    assert_equal 'dm1', ex['dataModelId']
    assert_equal 'el-explore-orders', ex['authoredId']
    assert_equal({ 'id' => 'met-orders-total_orders', 'liveId' => 'srv3/m0', 'name' => 'Total Orders' }, ex['metrics'][0])
    assert_equal 'ex-orders-order_id', ex['columns'][0]['id']
    assert_equal 'srv3/c0', ex['columns'][0]['liveId']
  end
end
