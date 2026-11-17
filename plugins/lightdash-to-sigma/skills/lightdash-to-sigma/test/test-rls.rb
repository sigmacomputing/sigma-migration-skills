#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline tests for detect-rls.rb (plan + gate) and apply-sigma-rls.rb.
#
#   ruby test/test-rls.rb

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'
require_relative '../scripts/detect-rls'
require_relative '../scripts/apply-sigma-rls'
require_relative '../scripts/convert-dm'

class RlsTest < Minitest::Test
  SCRIPTS = File.expand_path('../scripts', __dir__)
  FIXTURE = File.expand_path('../fixtures/jaffle-orders', __dir__)

  def envelope
    JSON.parse(JSON.generate(LightdashDm.build(LightdashModel.load(FIXTURE), 'orders', connection_id: 'c')[0]))
  end

  def test_simple_filters_parse
    p = LightdashRls.method(:parse_sql_filter)
    assert_equal({ 'column' => 'region', 'attribute' => 'region', 'operator' => 'in' }, p.call('${TABLE}.region IN (${lightdash.attributes.region})'))
    assert_equal({ 'column' => 'sales_region', 'attribute' => 'sr', 'operator' => 'in' }, p.call("sales_region in ('${ld.attr.sr}')"))
    assert_equal({ 'column' => 'region', 'attribute' => 'r', 'operator' => 'equals' }, p.call('${orders.region} = ${ld.attr.r}'))
    assert_equal({ 'column' => 'region', 'attribute' => 'r', 'operator' => 'equals' }, p.call("${lightdash.attributes.r} = ${TABLE}.region"))
  end

  def test_complex_filters_do_not_parse
    p = LightdashRls.method(:parse_sql_filter)
    assert_nil p.call('${TABLE}.region IN (${ld.attr.r}) OR ${TABLE}.is_public')
    assert_nil p.call('${TABLE}.deleted = false')
    assert_nil p.call('LOWER(${TABLE}.region) = ${ld.attr.r}')
    assert_nil p.call('${TABLE}.region IN (${ld.attr.a}, ${ld.attr.b})')
  end

  def test_fixture_plan_has_user_attribute_dm_row_filter_and_column_security
    plan = LightdashRls.plan(envelope)
    assert_equal [{ 'name' => 'region', 'source' => 'sql_filter on orders' }], plan['user_attributes']
    rf = plan['row_filters'].fetch(0)
    assert_equal 'el-orders', rf['element_id'], 'row filter lands on the data-model element, not the workbook'
    assert_equal 'col-orders-region', rf['column_id']
    assert_equal 'in', rf['operator']
    assert_match(/\[Region\] in user attribute region/, rf['sigma'])
    assert_match(/no rows when the user attribute is unset/, rf['fail_closed'])
    assert_equal 'ex-orders-margin', plan['column_security'][0]['column_id']
    assert_equal({ 'is_finance' => 'true' }, plan['column_security'][0]['required_attributes'])
    assert_empty plan['gaps']
  end

  def test_model_level_required_attributes_become_column_security
    env = envelope
    env['security']['models']['customers'] = { 'required_attributes' => { 'is_admin' => 'true' } }
    cs = LightdashRls.plan(env)['column_security']
    assert(cs.any? { |c| c['scope'] == 'model' && c['model'] == 'customers' && c['required_attributes'] == { 'is_admin' => 'true' } })
  end

  def complex_envelope
    env = envelope
    env['security']['models']['orders']['sql_filter'] = '${TABLE}.region IN (${lightdash.attributes.region}) OR ${TABLE}.is_returned'
    env
  end

  def test_complex_sql_filter_is_a_ledger_gap_and_fails_the_gate
    plan = LightdashRls.plan(complex_envelope)
    assert_empty plan['row_filters']
    gap = plan['gaps'].fetch(0)
    assert_equal 'scope-cut', gap['class']
    assert_equal 'sql_filter on orders', gap['item']
    assert_match(/human must decide/, gap['reason'])
    assert_equal 3, LightdashRls.gate(plan, ack: false, no_gate: false, ack_complex: nil)[0]
    assert_equal 3, LightdashRls.gate(plan, ack: true, no_gate: false, ack_complex: nil)[0], '--ack alone does not cover a gap'
    assert_equal 0, LightdashRls.gate(plan, ack: true, no_gate: false, ack_complex: 'reviewed by data owner')[0]
  end

  def test_gate_semantics
    plan = LightdashRls.plan(envelope)
    assert_equal 2, LightdashRls.gate(plan, ack: false, no_gate: false, ack_complex: nil)[0]
    assert_equal 0, LightdashRls.gate(plan, ack: true, no_gate: false, ack_complex: nil)[0]
    assert_equal 0, LightdashRls.gate(plan, ack: false, no_gate: true, ack_complex: nil)[0]
    none = LightdashRls.plan('security' => {}, 'sigmaDataModel' => {})
    assert_equal 0, LightdashRls.gate(none, ack: false, no_gate: false, ack_complex: nil)[0]
  end

  def run_detect(dir, env, *args)
    File.write(File.join(dir, 'dm.json'), JSON.generate(env))
    Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'detect-rls.rb'), '--envelope', File.join(dir, 'dm.json'),
                   '--out', File.join(dir, 'rls-plan.json'), *args)
  end

  def test_cli_exit_codes_and_plan_file
    Dir.mktmpdir do |dir|
      _o, err, st = run_detect(dir, envelope)
      assert_equal 2, st.exitstatus
      assert_match(/re-run with --ack/, err)
      assert_equal false, JSON.parse(File.read(File.join(dir, 'rls-plan.json')))['acknowledged']
      _o, _e, st = run_detect(dir, envelope, '--ack')
      assert_equal 0, st.exitstatus
      assert_equal true, JSON.parse(File.read(File.join(dir, 'rls-plan.json')))['acknowledged']
      _o, err, st = run_detect(dir, complex_envelope, '--ack')
      assert_equal 3, st.exitstatus
      assert_match(/GAP sql_filter on orders/, err)
      _o, _e, st = run_detect(dir, complex_envelope, '--no-gate')
      assert_equal 0, st.exitstatus
    end
  end

  def test_apply_plan_only_and_apply_refusals
    Dir.mktmpdir do |dir|
      run_detect(dir, envelope, '--ack')
      apply = lambda do |*args, env: {}|
        Open3.capture3(env, RbConfig.ruby, File.join(SCRIPTS, 'apply-sigma-rls.rb'), '--plan', File.join(dir, 'rls-plan.json'),
                       '--out', File.join(dir, 'rls-steps.json'), *args)
      end
      _o, _e, st = apply.call
      assert_equal 0, st.exitstatus
      steps = JSON.parse(File.read(File.join(dir, 'rls-steps.json')))
      assert_equal %w[create-user-attribute data-model-row-filter column-security], steps['steps'].map { |s| s['step'] }
      assert_equal 'plan', steps['mode']
      _o, _e, st = apply.call('--apply', env: { 'SIGMA_API_TOKEN' => '' })
      assert_equal 2, st.exitstatus
      _o, _e, st = apply.call('--apply', '--confirm', env: { 'SIGMA_API_TOKEN' => 'x' })
      assert_equal 0, st.exitstatus
      assert_equal 'apply-ready', JSON.parse(File.read(File.join(dir, 'rls-steps.json')))['mode']
      run_detect(dir, complex_envelope, '--no-gate')
      _o, _e, st = apply.call
      assert_equal 3, st.exitstatus
    end
  end

  def test_waived_complex_filter_applies_translatable_parts_and_ledgers_the_waiver
    Dir.mktmpdir do |dir|
      env = complex_envelope
      env['security']['models']['customers'] = { 'required_attributes' => { 'is_admin' => 'true' } }
      _o, _e, st = run_detect(dir, env, '--ack', '--ack-complex', 'data owner accepted')
      assert_equal 0, st.exitstatus
      File.write(File.join(dir, 'chart-gaps.json'), '[]')
      _o, err, st = Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'apply-sigma-rls.rb'), '--plan', File.join(dir, 'rls-plan.json'),
                                   '--out', File.join(dir, 'rls-steps.json'))
      assert_equal 0, st.exitstatus, err
      steps = JSON.parse(File.read(File.join(dir, 'rls-steps.json')))
      assert_equal 'waived', steps['mode']
      assert(steps['steps'].any? { |s| s['step'] == 'column-security' }, 'translatable parts still planned')
      entry = JSON.parse(File.read(File.join(dir, 'rls-gaps.json'))).fetch(0)
      assert_equal 'recorded-escape', entry['class']
      assert_match(/RLS waived: sql_filter on orders/, entry['item'])
      assert_match(/data owner accepted/, entry['reason'])
      assert_equal [entry], JSON.parse(File.read(File.join(dir, 'chart-gaps.json')))
      # no acknowledgement recorded -> still blocked
      run_detect(dir, env, '--no-gate')
      _o, _e, st = Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, 'apply-sigma-rls.rb'), '--plan', File.join(dir, 'rls-plan.json'),
                                  '--out', File.join(dir, 'rls-steps.json'))
      assert_equal 3, st.exitstatus
    end
  end
end
