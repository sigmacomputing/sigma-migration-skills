# test_export_pool_shape.rb — regression test for Task 3.2 (workbook code-rep
# document-wrapper, second call site). export_pool.rb#pooled_sql_probe (#7c)
# independently POSTs a probe workbook spec to /v2/workbooks/spec — the same
# live surface that now REJECTS a flat body with HTTP 400 (see code_rep.rb).
# Phase 2 (#608) added the Sigma::CodeRep adapter and Task 3.1 fixed the 6
# plugins' post-and-readback.* scripts, but export_pool.rb is a DIFFERENT
# call site that PR did not touch.
#
# Run: ruby shared/lib/tests/test_export_pool_shape.rb
require 'minitest/autorun'
require 'json'
require_relative '../code_rep'

# export_pool.rb assumes the caller already `require 'sigma_rest'`d (its own
# top comment says so); this test provides a minimal in-process stub instead
# of hitting the network, and captures the body handed to the workbook-spec
# POST so we can assert on its actual shape.
$pooled_post_body = nil
module Sigma
  class Error < StandardError; end

  def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
    if method == :post && path == '/v2/workbooks/spec'
      $pooled_post_body = JSON.parse(body)
      return { 'workbookId' => 'wb-test' }
    end
    if method == :post && path.include?('/export')
      req = JSON.parse(body)
      return { 'queryId' => req['elementId'] }
    end
    return "H\n1\n" if method == :get && path.start_with?('/v2/query/')
    return {} if method == :delete

    raise Error, "stub: unexpected #{method} #{path}"
  end
end

# export_pool.rb bare-`require`s 'code_rep' (matching the real caller
# convention of `$LOAD_PATH.unshift File.expand_path('lib', __dir__)` before
# requiring its libs) — extend the load path the same way here.
$LOAD_PATH.unshift(File.expand_path('..', __dir__))
require_relative '../export_pool'

class TestExportPoolShape < Minitest::Test
  # The adapter itself (brief's literal check): wrap() always nests.
  def test_workbook_post_body_is_wrapped
    doc  = { 'schemaVersion' => 1, 'pages' => [], 'elements' => [],
             'layout' => '', 'kind' => 'workbook' }
    body = Sigma::CodeRep.wrap(doc, extra: { 'name' => 'n', 'folderId' => 'f' })
    assert_equal doc, body['document'], 'workbook POST body must nest the document'
    refute body.key?('pages')
  end

  # The real regression signal: export_pool.rb's own probe-workbook POST call
  # site (pooled_sql_probe, ~line 429) must ROUTE THROUGH the adapter — not
  # spread a flat spec straight into the POST body. Pre-fix, this fails
  # because $pooled_post_body carries top-level `pages`/`schemaVersion` and
  # no `document` key at all — exactly the flat shape the live surface 400s.
  def test_pooled_sql_probe_posts_wrapped_document
    entries  = [{ 'sql' => 'SELECT 1', 'columns' => %w[A B] }]
    deadline = ExportPool::Deadline.new(30)

    ExportPool.pooled_sql_probe('conn-1', entries, deadline, pool: 1,
                                folder_id: 'f1', name: 'probe-x')

    refute_nil $pooled_post_body, 'pooled_sql_probe never POSTed to /v2/workbooks/spec'
    assert $pooled_post_body.key?('document'),
           'POST body must nest the workbook document under a top-level `document` key'
    assert_equal 1, $pooled_post_body['document']['schemaVersion']
    assert $pooled_post_body['document']['pages'].is_a?(Array)
    assert $pooled_post_body['document']['elements'].is_a?(Array)
    assert_nil $pooled_post_body['document']['pages'].first['elements'],
               'workbook elements must be flat document elements'
    assert_includes $pooled_post_body['document']['layout'], 'elementId="probe0"',
                    'create must carry complete element placement in required layout'
    refute $pooled_post_body.key?('pages'),
           'pages must not remain top-level (flat body is HTTP 400 on this surface)'
    refute $pooled_post_body.key?('schemaVersion'),
           'schemaVersion must not remain top-level'
    assert_equal 'probe-x', $pooled_post_body['name'], 'metadata (name) must stay outside document'
    assert_equal 'f1', $pooled_post_body['folderId'], 'metadata (folderId) must stay outside document'
  end
end
