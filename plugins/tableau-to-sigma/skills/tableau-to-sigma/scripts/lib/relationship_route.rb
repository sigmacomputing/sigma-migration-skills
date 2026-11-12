# frozen_string_literal: true

require 'json'

# Which relationship rule a workdir is judged by. The reused-DM evidence route
# (relationship-map.json) applies only to a data model someone deliberately
# named with an explicit --reuse-dm <id> that this workdir did not post itself;
# everything else keeps the strict relationship-coverage.json rule. The route
# is persisted in migrate-state.json by the orchestrator and read from there —
# never inferred from the presence of a map file.
module RelationshipRoute
  EVIDENCE = 'reused-dm-evidence'

  module_function

  def eligible?(workdir:, reuse_dm:)
    return false unless reuse_dm.is_a?(String) && !reuse_dm.strip.empty?
    !posted_ids(workdir).include?(reuse_dm.strip)
  end

  def posted_ids(workdir)
    path = File.join(workdir.to_s, 'posted-datamodels.jsonl')
    return [] unless File.file?(path)
    File.readlines(path).map do |row|
      JSON.parse(row)['id'].to_s
    rescue JSON::ParserError, NoMethodError, TypeError
      nil
    end.compact
  end

  # Re-checked at gate time, not just trusted: the route stands only while the
  # state says the shipped model IS the reused one (reused_dm) and this
  # workdir never posted that model id itself.
  def current(workdir, state_file: 'migrate-state.json')
    path = File.join(workdir.to_s, state_file)
    return nil unless File.file?(path)
    state = JSON.parse(File.read(path))
    return nil unless state.is_a?(Hash) && state['relationship_route'] == EVIDENCE
    dm_id = state['data_model_id'].to_s
    return nil if dm_id.empty? || state['reused_dm'] == false || posted_ids(workdir).include?(dm_id)
    EVIDENCE
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Once the reuse decision is final. Pass 1 checks relationship coverage
  # before it knows whether reuse survives (a reuse candidate can still be
  # refused and a fresh converter model built); on the evidence route that
  # check is DEFERRED, not skipped. If reuse was abandoned the route is
  # cleared and the deferred strict STOP fires before any Sigma write.
  # --finalize: re-read the LIVE reused model into dm-spec-reused.json (it may
  # have been edited between passes). On failure the pass-1 copy is removed so
  # the relationship gate blocks (input-missing) instead of judging evidence
  # against a model it could not confirm. Returns [ok, message].
  def refresh_reused_model(workdir, fetch:)
    path = File.join(workdir.to_s, 'dm-spec-reused.json')
    live = fetch.call
    raise ArgumentError, 'readback has no pages' unless live.is_a?(Hash) && live['pages'].is_a?(Array)
    File.write(path, JSON.pretty_generate(live))
    [true, "re-read the live reused model into #{path}"]
  rescue StandardError => e
    File.delete(path) if File.exist?(path)
    [false, "#{e.class}: #{e.message.to_s[0, 160]}"]
  end

  def settle(route:, reused:, coverage_deferred:)
    return { route: nil, stop: false } if route.nil?
    return { route: route, stop: false } if reused
    { route: nil, stop: coverage_deferred ? true : false }
  end
end
