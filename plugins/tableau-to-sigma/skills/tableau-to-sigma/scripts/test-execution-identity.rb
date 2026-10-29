#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/execution_identity'

class ExecutionIdentityTest < Minitest::Test
  def test_content_identity_and_history_without_source_or_credentials
    Dir.mktmpdir do |base|
      skill = File.join(base, 'plugin/skills/example')
      work = File.join(base, 'work')
      FileUtils.mkdir_p([File.join(skill, 'scripts'), File.join(skill, 'converter'), work])
      File.write(File.join(skill, 'SKILL.md'), 'synthetic instructions')
      File.write(File.join(skill, 'scripts/run.rb'), 'puts 1')
      File.write(File.join(skill, 'converter/tableau.mjs'), 'export const fixture = 1;')
      File.write(File.join(work, 'source.twb'), 'PRIVATE-SOURCE-SENTINEL')
      File.write(File.join(work, 'auth.json'), 'PRIVATE-AUTH-SENTINEL')
      first = ExecutionIdentity.record(work, skill: skill)
      assert_equal false, first['implementation_changed']
      assert_nil first['git_revision']
      assert_equal File.realpath(skill), first['skill_path']
      second = ExecutionIdentity.record(work, skill: skill)
      assert_equal first['implementation_sha256'], second['implementation_sha256']
      refute second['implementation_changed']
      File.write(File.join(skill, 'scripts/run.rb'), 'puts 2')
      third = ExecutionIdentity.record(work, skill: skill)
      assert third['implementation_changed']
      refute_equal first['implementation_sha256'], third['implementation_sha256']
      ExecutionIdentity.record_converter(work, File.join(skill, 'converter/tableau.mjs'))
      final = JSON.parse(File.read(File.join(work, 'execution-identity.json')))
      assert_equal Digest::SHA256.file(File.join(skill, 'converter/tableau.mjs')).hexdigest, final.dig('converter', 'sha256')
      history = File.read(File.join(work, 'execution-history.jsonl'))
      assert_equal 4, history.lines.size
      refute_includes history, 'PRIVATE-SOURCE-SENTINEL'
      refute_includes history, 'PRIVATE-AUTH-SENTINEL'
      assert_equal 'PRIVATE-SOURCE-SENTINEL', File.read(File.join(work, 'source.twb'), encoding: 'UTF-8')
    end
  end
end
