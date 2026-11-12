#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'json'
source = File.read(File.join(__dir__, 'run-ground-truth.rb'), encoding: 'UTF-8')
eval(source.match(/^def ground_truth_folder.*?\n^end$/m)[0]) # rubocop:disable Security/Eval -- first-party helper

class GroundTruthFolderTest < Minitest::Test
  def test_only_explicit_or_structured_folder_identity_is_used
    Dir.mktmpdir do |work|
      assert_nil ground_truth_folder(work)
      assert_equal 'explicit', ground_truth_folder(work, 'explicit')
      mission = File.join(work, 'mission.json')
      File.write(mission, JSON.generate('destination' => { 'provenance' => 'stated', 'value' => 'Sales Workspace' }))
      assert_nil ground_truth_folder(work)
      File.write(mission, JSON.generate('destination' => { 'provenance' => 'stated', 'value' => { 'folderId' => 'mission-id' } }))
      assert_equal 'mission-id', ground_truth_folder(work)
      File.write(File.join(work, 'dm-spec.json'), JSON.generate('folderId' => 'model-id'))
      assert_equal 'model-id', ground_truth_folder(work)
      File.write(File.join(work, 'wb-spec.json'), JSON.generate('folderId' => 'workbook-id'))
      assert_equal 'workbook-id', ground_truth_folder(work)
      assert_equal 'explicit', ground_truth_folder(work, 'explicit')
    end
  end
end
