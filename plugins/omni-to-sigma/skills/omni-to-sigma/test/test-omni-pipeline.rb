#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit tests for OmniRest, omni-discover.rb, post-omni-dm.rb,
# verify-omni-parity.rb, and migrate-omni.rb (all offline / stubbed).
#
#   ruby test/test-omni-pipeline.rb

require 'tmpdir'
require 'json'
require_relative '../scripts/lib/omni_rest'
require_relative '../scripts/omni-discover'
require_relative '../scripts/post-omni-dm'
require_relative '../scripts/verify-omni-parity'
require_relative '../scripts/migrate-omni'

$failures = 0
def eq(a, b, m)
  if a == b
    puts "  ok: #{m}"
  else
    $failures += 1
    puts "  FAIL: #{m}\n    exp #{b.inspect}\n    got #{a.inspect}"
  end
end

FakeResponse = Struct.new(:code, :body, :headers) do
  def [](key)
    (headers || {})[key]
  end
end

class FakeHTTP
  attr_reader :call_count

  def initialize(*responses)
    @responses = responses
    @call_count = 0
  end

  def request(_req)
    res = @responses[@call_count] || @responses.last
    @call_count += 1
    res
  end
end

puts '== OmniRest: URI building, 429 retry, and credential errors =='
ENV['OMNI_BASE_URL'] = 'https://acme.omniapp.co/'
ENV['OMNI_API_TOKEN'] = 'omni-secret-token'

uri = OmniRest.build_uri('/api/v1/models', { 'modelKind' => 'SHARED' })
eq(uri.to_s, 'https://acme.omniapp.co/api/v1/models?modelKind=SHARED', 'build_uri strips trailing slash and encodes query')

orig_http_for = OmniRest.method(:http_for)
fake = FakeHTTP.new(
  FakeResponse.new('429', '', { 'Retry-After' => '0' }),
  FakeResponse.new('200', '{"records":[{"id":"m1"}]}', {})
)
OmniRest.define_singleton_method(:http_for) { |_u| fake }
res = OmniRest.get('/api/v1/models')
eq(res, { 'records' => [{ 'id' => 'm1' }] }, 'OmniRest.get retries once on 429 and parses JSON')
eq(fake.call_count, 2, 'OmniRest.get made 2 HTTP calls on a single 429')
OmniRest.define_singleton_method(:http_for, orig_http_for)

saved_tok = ENV.delete('OMNI_API_TOKEN')
begin
  OmniRest.get('/api/v1/models')
  $failures += 1
  puts '  FAIL: OmniRest.get should raise when OMNI_API_TOKEN is missing'
rescue OmniRest::Error => e
  eq(e.message, 'OMNI_API_TOKEN not set', 'missing token raises clear OmniRest::Error')
ensure
  ENV['OMNI_API_TOKEN'] = saved_tok
end

puts '== omni-discover.rb: unpack_model_yaml and infer_model_id_and_topic =='
Dir.mktmpdir do |dir|
  files = {
    'orders.topic' => "base_view: orders\n",
    'public/orders.view' => { 'content' => "schema: public\ntable_name: orders\n" },
    '../evil.view' => 'ignored'
  }
  written = unpack_model_yaml(files, dir)
  eq(written, ['orders.topic', 'public/orders.view'], 'unpack_model_yaml writes nested files and rejects .. traversal')
  eq(File.exist?(File.join(dir, 'public/orders.view')), true, 'nested view file exists on disk')
end

model_id, topic = infer_model_id_and_topic({
  'dashboard' => {
    'queryPresentations' => [
      { 'query' => { 'modelId' => 'm-123', 'join_paths_from_topic_name' => 'orders' } }
    ]
  }
})
eq([model_id, topic], %w[m-123 orders], 'infer_model_id_and_topic extracts modelId and topic from export')

puts '== post-omni-dm.rb: unwrap_dm_spec and element_lookup_from_readback =='
authored_els = [
  { 'id' => 'el-orders', 'name' => 'ORDERS', 'columns' => [{ 'id' => 'col-orders-id', 'name' => 'Id' }] },
  { 'id' => 'el-topic-orders', 'name' => 'Orders', 'columns' => [{ 'id' => 'ex-col-orders-id', 'name' => 'Id' }] }
]
readback_spec = {
  'pages' => [{
    'elements' => [
      { 'id' => 'inode-table-1', 'name' => 'ORDERS', 'columns' => [{ 'id' => 'c1', 'name' => 'Id' }] },
      { 'id' => 'inode-topic-1', 'name' => 'Orders', 'columns' => [{ 'id' => 'c2', 'name' => 'Id' }] }
    ]
  }]
}
lookup = element_lookup_from_readback(readback_spec, authored_els, data_model_id: 'dm-999')
eq(lookup['topic-orders']['elementId'], 'inode-topic-1', 'readback maps el-topic-orders to server elementId inode-topic-1')
eq(lookup['topic-orders']['dataModelId'], 'dm-999', 'readback records dataModelId')

puts '== verify-omni-parity.rb: rows_match?, omni_response_to_rows, summarize_parity =='
eq(rows_match?([['2025-01', '100.0']], [['2025-01', 100]]), true, 'rows_match? tolerates numeric string vs float formatting')
eq(omni_response_to_rows({ 'rows' => [{ 'a' => 1, 'b' => 2 }, { 'a' => 3, 'b' => 4 }] }),
   [[1, 2], [3, 4]],
   'omni_response_to_rows normalizes array-of-hashes into row arrays')
summary = summarize_parity([{ 'chart' => 'Rev', 'pass' => true }, { 'chart' => 'Cnt', 'pass' => false }], workbook_id: 'wb-1')
eq(summary['status'], 'FAIL', 'summarize_parity reports FAIL when any chart fails')
eq(summary['charts_pass'], 1, 'summarize_parity counts passing charts')
eq(summary['charts_fail'], 1, 'summarize_parity counts failing charts')

puts '== migrate-omni.rb: PHASE_ORDER and run_script! =='
eq(PHASE_ORDER,
   %w[discover detect-rls convert-dm reuse-check post-dm build-workbook post-workbook verify-parity assert-phase6],
   'migrate-omni PHASE_ORDER covers C2 through C9')

if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
