#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative 'lib/sql_provenance'

class ActiveDmSpecTest < Minitest::Test
  def test_explicit_active_binding_is_not_replaced_by_mtime_or_matching_old_hash
    Dir.mktmpdir do |work|
      active = File.join(work, 'dm-spec.json')
      other = File.join(work, 'dm-spec-reused.json')
      File.write(active, '{"pages":[]}')
      File.write(File.join(work, 'dm-ids.json'), '{"dataModelId":"model-fixture"}')
      SqlProvenance.record_active_spec(work, active, 'model-fixture')
      File.write(other, '{"pages":[]}')
      File.utime(Time.now + 60, Time.now + 60, other)
      assert_equal active, SqlProvenance.active_spec_path(work)
      File.write(active, '{"pages":[],"changed":true}')
      assert_raises(ArgumentError) { SqlProvenance.active_spec_path(work) }
      # The other file still has the old hash, but is not the model we posted.
      File.write(active, '{"pages":[]}')
      File.write(File.join(work, 'dm-ids.json'), '{"dataModelId":"other-model"}')
      assert_raises(ArgumentError) { SqlProvenance.active_spec_path(work) }
      File.delete(File.join(work, 'active-dm-spec.json'))
      assert_raises(ArgumentError) { SqlProvenance.active_spec_path(work) }
    end
  end
end
