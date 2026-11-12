#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof: validate-spec.rb crashed with a Ruby `sort` ArgumentError
# ("comparison of String with Integer/nil failed") while building an error
# message on a valid patched spec, so the operator skipped the validator.
# Element / metric / prefix names can be nil or non-String (an unnamed DM
# helper, a numeric name); message lists must sort them safely and the
# validator must REPORT, never crash.

require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/workbook_code'

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

legacy = {
  'schemaVersion' => 1, 'name' => 'sort-safe', 'folderId' => 'f',
  'pages' => [
    { 'id' => 'pg-0', 'name' => 'Data', 'elements' => [
      { 'id' => 'master', 'kind' => 'table', 'name' => 'Master',
        'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-1', 'elementId' => 'fact' },
        'columns' => [{ 'id' => 'm1', 'name' => 'Revenue', 'formula' => '[Fact/Revenue]' }] }
    ] },
    { 'id' => 'pg-1', 'name' => 'Dash', 'elements' => [
      { 'id' => 'el-1', 'kind' => 'table', 'name' => 'Detail', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'columns' => [{ 'id' => 'c1', 'name' => 'Odd', 'formula' => '[Nope/Revenue]' }] }
    ] }
  ]
}
spec = WorkbookCode.canonicalize(legacy)
Dir.mktmpdir do |d|
  sp = File.join(d, 'wb-spec.json')
  File.write(sp, JSON.generate(spec))
  ctx = File.join(d, 'dm-ids.json')
  # DM element names as the readback can carry them: a String, an Integer, a nil.
  File.write(ctx, JSON.generate('elements' => [{ 'id' => 'fact', 'name' => 'Fact' }, { 'id' => 'h', 'name' => 2024 },
                                               { 'id' => 'n', 'name' => nil }]))
  out, st = Open3.capture2e(RbConfig.ruby, File.join(__dir__, 'validate-spec.rb'), '--type', 'workbook', '--dm-context', ctx, sp)
  ok(!out.include?('ArgumentError') && !out.include?('comparison of'), "no sort crash (#{out.lines.grep(/Error|comparison/).first.to_s.strip})")
  ok(out.include?('prefix "Nope" unknown') && out.include?('2024') && out.include?('Fact'),
     'the unknown-prefix error is REPORTED, listing every known name as text')
  ok(st.exitstatus != 0 && out =~ /errors/, 'exits non-zero with an error count (a report, not a crash)')
end

puts
puts $fails.empty? ? 'ALL PASS' : "FAILURES (#{$fails.size})"
exit($fails.empty? ? 0 : 1)
