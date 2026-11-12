#!/usr/bin/env ruby
# frozen_string_literal: true
# test-validate-spec-union.rb — an element whose source is `kind: union` references
# its output columns with the prefix `Union of N Sources` (N = sources.length);
# the live /v2/workbooks/spec/verify rejects the union's own name. validate-spec.rb
# must accept exactly that prefix and still reject a wrong N.
# Creds-free, network-free, synthetic data only.
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'shellwords'

VALIDATE = File.join(__dir__, 'validate-spec.rb')
RUBY = RbConfig.ruby
$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

def spec_with(formula, union_name = 'Both')
  {
    'name' => 'T',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [{ 'id' => 'page-data', 'name' => 'Data' }],
      'elements' => [
        { 'id' => 'a', 'kind' => 'table', 'name' => 'A',
          'source' => { 'kind' => 'sql', 'connectionId' => 'c', 'statement' => 'SELECT 1 AS N' },
          'columns' => [{ 'id' => 'a1', 'name' => 'N', 'formula' => '[Custom SQL/N]' }] },
        { 'id' => 'b', 'kind' => 'table', 'name' => 'B',
          'source' => { 'kind' => 'sql', 'connectionId' => 'c', 'statement' => 'SELECT 2 AS N' },
          'columns' => [{ 'id' => 'b1', 'name' => 'N', 'formula' => '[Custom SQL/N]' }] },
        { 'id' => 'u', 'kind' => 'table', 'name' => union_name,
          'source' => { 'kind' => 'union',
                        'sources' => [{ 'kind' => 'table', 'elementId' => 'a' }, { 'kind' => 'table', 'elementId' => 'b' }],
                        'matches' => [{ 'outputColumnName' => 'N', 'sourceColumns' => ['[N]', '[N]'] }] },
          'columns' => [{ 'id' => 'u1', 'name' => 'N', 'formula' => formula }] }
      ],
      'layout' => '<Page type="grid" id="page-data"><Element elementId="a"/><Element elementId="b"/><Element elementId="u"/></Page>'
    }
  }
end

def run(formula, union_name = 'Both')
  Dir.mktmpdir do |d|
    p = File.join(d, 'spec.json')
    File.write(p, JSON.generate(spec_with(formula, union_name)))
    # Test harness: every interpolated value is shell-escaped (a fixed script and temp paths).
    # nosemgrep: ruby.lang.security.dangerous-subshell.dangerous-subshell
    out = `#{RUBY.shellescape} #{VALIDATE.shellescape} --type workbook #{p.shellescape} 2>&1`
    [$?.success?, out]
  end
end

good, out = run('[Union of 2 Sources/N]')
ok('accepts [Union of 2 Sources/N] on a two-source union', good && !out.include?('prefix "Union of 2 Sources" unknown'))
bad, out = run('[Union of 3 Sources/N]')
ok('rejects [Union of 3 Sources/N] on a two-source union', !bad && out.include?('prefix "Union of 3 Sources" unknown'))
named, out = run('[Both/N]')
ok("rejects the union element's own name as a prefix", !named && out.include?('Union of 2 Sources'))
auto, out = run('[Union of 2 Sources/N]', 'Union of 2 Sources')
ok('accepts the prefix when the union is auto-named "Union of 2 Sources"', auto && !out.include?('not by its own name'))

exit($fail.zero? ? 0 : 1)
