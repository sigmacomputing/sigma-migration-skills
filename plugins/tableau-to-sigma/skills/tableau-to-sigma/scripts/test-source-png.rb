#!/usr/bin/env ruby
# frozen_string_literal: true

# Stress 4: discovery saved dashboards/Fulfillment_Performance.png, the RCF
# render looked for "Fulfillment Performance.png" and wrote no source
# composite (the agent copied the PNGs by hand). lib/source_png.rb resolves both.

require 'tmpdir'
require 'fileutils'
require_relative 'lib/source_png'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |wd|
  FileUtils.mkdir_p(File.join(wd, 'dashboards'))
  FileUtils.touch(File.join(wd, 'dashboards', 'Fulfillment_Performance.png'))
  FileUtils.touch(File.join(wd, 'dashboards', 'Q_A_-_Ops.png'))
  FileUtils.touch(File.join(wd, 'dashboards', 'Store Network.png'))
  ok(SourcePng.path(wd, 'Fulfillment Performance')&.end_with?('Fulfillment_Performance.png'), 'page name with spaces → discovery underscore file')
  ok(SourcePng.path(wd, 'Store Network')&.end_with?('Store Network.png'), 'exact name still wins')
  ok(SourcePng.path(wd, 'Q&A - Ops')&.end_with?('Q_A_-_Ops.png'), 'punctuation runs collapse like tableau-discover')
  ok(SourcePng.path(wd, 'store-network')&.end_with?('Store Network.png'), 'case/punctuation-insensitive fallback')
  ok(SourcePng.path(wd, 'Missing Board').nil?, 'no file → nil')
  ok(SourcePng.path(wd, '').nil?, 'empty name → nil')
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
