# frozen_string_literal: true
# test_plugin_embed.rb — run directly: ruby shared/lib/test_plugin_embed.rb
require 'json'
require_relative 'plugin_embed'

$failures = 0
def check(desc)
  ok = yield
  puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}")
  $failures += 1 unless ok
end

# Deep-sort hashes/arrays so twin/golden comparison is key-order-independent.
def sort_deep(o)
  case o
  when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
  when Array then o.map { |e| sort_deep(e) }
  else o
  end
end

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'plugin_embed_golden.json')))

check('gauge plugin embed matches golden (sorted-key identical)') do
  el = PluginEmbed.build(id: 'gauge-el', plugin_id: 'pl-1', source_element_id: 'tbl-1',
                          bindings: { 'value' => 'actual', 'target' => 'target' },
                          extra_config: { 'format' => '$.3~s' })
  JSON.generate(sort_deep(el)) == JSON.generate(sort_deep(golden))
end

check('numeric extra_config value is coerced to a string') do
  el = PluginEmbed.build(id: 'gauge-el', plugin_id: 'pl-1', source_element_id: 'tbl-1',
                          bindings: { 'value' => 'actual' },
                          extra_config: { 'decimals' => 2 })
  el['config']['decimals'] == '2' && el['config']['decimals'].is_a?(String)
end

check('empty id raises ArgumentError') do
  begin
    PluginEmbed.build(id: '', plugin_id: 'pl-1', source_element_id: 'tbl-1', bindings: {})
    false
  rescue ArgumentError
    true
  end
end

check('empty plugin_id raises ArgumentError') do
  begin
    PluginEmbed.build(id: 'gauge-el', plugin_id: '', source_element_id: 'tbl-1', bindings: {})
    false
  rescue ArgumentError
    true
  end
end

check('empty source_element_id raises ArgumentError') do
  begin
    PluginEmbed.build(id: 'gauge-el', plugin_id: 'pl-1', source_element_id: '', bindings: {})
    false
  rescue ArgumentError
    true
  end
end

exit($failures.zero? ? 0 : 1)
