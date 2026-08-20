#!/usr/bin/env ruby
# Create a workbook from a spec, GET it back, and diff the actions[] arrays.
#
# WHY THIS EXISTS: /verify proves nothing. Three shapes on this workstream
# passed /verify and were then dropped or rejected — repeatFrom on containers
# (accepted, dropped), set-control-value with control=<elementId> (accepted by
# verify, REJECTED by create), and tabs[].elementIds (accepted by verify AND
# create, then silently dropped on readback). Only a GET readback diff settles
# a shape question.
#
# Env-gated like the other probes: without SIGMA_API_TOKEN this SKIPs (exit 0)
# rather than failing, so it never blocks the offline sweep.
#
# Usage:
#   probe-actions-readback.rb --spec chart-specs.json --expect-actions actions-emitted.json
require 'json'
require 'optparse'
require 'net/http'
require 'uri'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'action_ledger'
require 'probe_registry'

opts = {}
OptionParser.new do |p|
  p.on('--spec PATH')            { |v| opts[:spec] = v }
  p.on('--expect-actions PATH')  { |v| opts[:expect] = v }
  p.on('--base-url URL')         { |v| opts[:base] = v }
end.parse!

token = ENV['SIGMA_API_TOKEN']
if token.nil? || token.empty?
  warn 'SKIP: SIGMA_API_TOKEN not set — readback probe not run (this is not a pass)'
  exit 0
end
base = opts[:base] || ENV['SIGMA_BASE_URL'] or abort('missing --base-url / SIGMA_BASE_URL')

spec     = JSON.parse(File.read(opts[:spec]))
expected = ActionLedger.read_manifest(opts[:expect])

def api(method, url, token, body = nil)
  uri = URI(url)
  req = case method
        when :post then Net::HTTP::Post.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        else Net::HTTP::Get.new(uri)
        end
  req['Authorization'] = "Bearer #{token}"
  req['Content-Type']  = 'application/json'
  req.body = JSON.generate(body) if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
end

code, created = api(:post, "#{base}/v2/workbooks/spec", token, spec)
abort "create FAILED (#{code}): #{created.inspect[0, 800]}" unless (200..299).cover?(code)
wb_id = created['workbookId'] || created.dig('workbook', 'workbookId')
abort "create returned no workbookId: #{created.inspect[0, 400]}" if wb_id.to_s.empty?

# Register the workbook immediately after create, before any readback, so a
# failure between create and readback is still tracked in the probe registry.
ProbeRegistry.created(wb_id, name: "ZZ probe-actions-readback (#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')})", script: 'probe-actions-readback.rb')

begin
  code, got = api(:get, "#{base}/v2/workbooks/#{wb_id}/spec", token)
  abort "readback FAILED (#{code})" unless (200..299).cover?(code)

  # The spec may or may not be wrapped in a `document` envelope depending on the
  # release — unwrap before walking so the diff is not comparing two shapes.
  root = got['document'] || got
  found = {}
  walk = lambda do |node|
    case node
    when Hash
      Array(node['actions']).each { |a| found[a['id']] = a }
      node.each_value { |v| walk.call(v) }
    when Array then node.each { |v| walk.call(v) }
    end
  end
  walk.call(root)

  fails = []
  expected.each do |entry|
    id  = entry['actionId']
    got_action = found[id]
    if got_action.nil?
      fails << "action #{id} (#{entry.dig('source', 'caption')}) SILENTLY DROPPED — " \
               'present in the posted spec, absent from the readback'
      next
    end
    if got_action['trigger'] != entry['trigger']
      fails << "action #{id}: trigger #{entry['trigger'].inspect} came back " \
               "#{got_action['trigger'].inspect}"
    end
    # Subset comparison: check every key in the posted effects is present and
    # equal in the readback, but tolerate server-added keys (they're informational).
    posted_effects = Array(entry['effects'])
    got_effects = Array(got_action['effects'])
    added_keys = {}
    posting_issues = []
    # HOW EFFECTS ARE PAIRED. Emitted effects carry NO `id` key — nothing in
    # build-charts-from-signals.rb mints one and the API does not require one —
    # so an `id`-equality find compares nil == nil. On a HEALTHY workbook that
    # returned got_effects[0] for EVERY posted effect: a two-effect action
    # reported its second effect DROPPED, with an empty id in the message, the
    # first time this harness ran with credentials. Two id-less effects also
    # both resolved to the same readback effect, so a genuine drop could hide
    # behind a duplicate match.
    #
    # Pair, in order: (1) by `id`, but only when BOTH sides actually carry one;
    # (2) by a stable composite signature — the effect name plus whichever
    # field identifies its target (`control` for set-control-value, `target`
    # for navigate/refresh-element, and so on) — because the server is free to
    # reorder effects; (3) positionally, when the effect name at that index
    # agrees. Every match CONSUMES its readback effect, so no two posted
    # effects can pair with the same one.
    consumed = {}
    signature = lambda do |eff|
      [eff['effect'], eff['control'], eff['target'], eff['overlayId'],
       eff['tabbedContainer'], eff['selectedTab'], eff['url'], eff['document'],
       eff['scope'], eff['table']]
    end
    posted_effects.each_with_index do |posted_eff, pi|
      next unless posted_eff.is_a?(Hash)
      posted_id = posted_eff['id'].to_s
      # Without an id there is nothing to name the effect by, so name it the
      # only way that stays useful in a failure message: position + kind.
      label = posted_id.empty? ? "effects[#{pi}] (#{posted_eff['effect'].inspect})" : posted_id
      gi = nil
      unless posted_id.empty?
        gi = got_effects.each_index.find do |i|
          !consumed[i] && got_effects[i].is_a?(Hash) && got_effects[i]['id'].to_s == posted_id
        end
      end
      gi ||= got_effects.each_index.find do |i|
        !consumed[i] && got_effects[i].is_a?(Hash) &&
          signature.call(got_effects[i]) == signature.call(posted_eff)
      end
      if gi.nil? && got_effects[pi].is_a?(Hash) && !consumed[pi] &&
         got_effects[pi]['effect'] == posted_eff['effect']
        gi = pi
      end
      if gi.nil?
        posting_issues << "#{label} DROPPED"
        next
      end
      consumed[gi] = true
      matching = got_effects[gi]
      # Check every posted key is present and equal
      posted_eff.each do |key, val|
        unless matching.key?(key)
          posting_issues << "#{label}: key #{key.inspect} dropped on readback"
          next
        end
        next if matching[key] == val
        posting_issues << "#{label}: key #{key.inspect} " \
                          "posted #{val.inspect}, readback #{matching[key].inspect}"
      end
      # Collect any server-added keys (informational, not a failure)
      matching.each { |key, _| added_keys[key] = true unless posted_eff.key?(key) }
    end
    if posting_issues.any?
      fails << "action #{id}: #{posting_issues.join('; ')}"
    end
    if added_keys.any?
      puts "  info: action #{id} — server added keys on readback: #{added_keys.keys.inspect}"
    end
  end

  puts "workbook #{wb_id}: #{expected.length} expected action(s), #{found.length} in readback"
  if fails.empty?
    puts 'OK: every emitted action survived the readback byte-identical'
  else
    puts "FAILED (#{fails.length}):"
    fails.each { |f| puts "  - #{f}" }
    exit 1
  end
ensure
  # Clean up the workbook in ensure so any failure path is still tracked.
  if wb_id
    begin
      code, _resp = api(:delete, "#{base}/v2/files/#{wb_id}", token)
      outcome = (200..299).cover?(code) ? 'deleted' : (code == 404 ? '404' : 'failed')
      ProbeRegistry.cleaned(wb_id, via: 'ensure', outcome: outcome)
    rescue StandardError => e
      ProbeRegistry.cleaned(wb_id, via: 'ensure', outcome: 'failed')
    end
  end
end
