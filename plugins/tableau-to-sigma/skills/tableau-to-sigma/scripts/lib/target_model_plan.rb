# frozen_string_literal: true

# Cardinality-aware target-model planning for Tableau object graphs.
#
# The Tableau wire records relationships, not a trustworthy physical target
# topology. This module combines that wire with optional warehouse profiles and
# emits an executable, fail-closed plan consumed by migrate-tableau.rb.

require 'json'
require 'time'

module TargetModelPlan
  VERSION = 1
  MODES = %w[source-faithful remodeled-star reuse-existing-dm].freeze

  class Error < StandardError; end

  module_function

  def normalize(name)
    name.to_s.split('.').last.to_s.upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_|_\z/, '')
  end

  def profile_index(payload)
    rows = if payload.is_a?(Hash) && payload['tables'].is_a?(Array)
             payload['tables']
           elsif payload.is_a?(Array)
             payload
           elsif payload.is_a?(Hash)
             payload.map { |name, value| (value || {}).merge('name' => name) }
           else
             []
           end
    rows.each_with_object({}) do |row, out|
      next unless row.is_a?(Hash)
      name = row['name'] || row['table'] || row['fqn']
      out[normalize(name)] = row.merge('name' => name) unless normalize(name).empty?
    end
  end

  def apply_join_evidence(object_graph_plan, join_plan)
    copy = Marshal.load(Marshal.dump(object_graph_plan))
    entries = Array(join_plan.is_a?(Hash) ? join_plan['entries'] : join_plan)
    copy.fetch('datasources', []).each do |datasource|
      Array(datasource['relationships']).each do |relationship|
        entries.each do |entry|
          next unless entry['status'] == 'unique'
          endpoints = [normalize(entry['left']), normalize(entry['right'])].compact
          source_endpoints = [normalize(relationship['first']), normalize(relationship['second'])]
          next unless endpoints.sort == source_endpoints.sort
          if normalize(entry['right']) == normalize(relationship['first'])
            relationship['first_db_unique'] = true
            relationship['first_unique_proof'] = 'join-plan'
          elsif normalize(entry['right']) == normalize(relationship['second'])
            relationship['second_db_unique'] = true
            relationship['second_unique_proof'] = 'join-plan'
          end
        end
      end
    end
    copy
  end

  def key_set(keys)
    Array(keys).flatten.compact.map { |key| normalize(key) }.reject(&:empty?).uniq.sort
  end

  def unique_on?(profile, keys)
    wanted = key_set(keys)
    return false if wanted.empty? || !profile
    declared = profile['unique_on']
    candidates =
      if declared.nil?
        []
      elsif declared.is_a?(Array) && declared.all? { |item| item.is_a?(String) }
        [declared]
      else
        Array(declared).dup
      end
    candidates << Array(profile['grain_keys']) if profile['unique'] == true
    candidates.any? { |candidate| key_set(candidate) == wanted }
  end

  def endpoint_unique?(relationship, side, profile)
    relationship["#{side}_db_unique"] == true ||
      unique_on?(profile, Array(relationship['keys']).map { |pair| side == 'first' ? pair[0] : pair[1] })
  end

  def relation_plan(relationship, profiles)
    first_name = relationship['first']
    second_name = relationship['second']
    first_profile = profiles[normalize(first_name)]
    second_profile = profiles[normalize(second_name)]
    first_unique = endpoint_unique?(relationship, 'first', first_profile)
    second_unique = endpoint_unique?(relationship, 'second', second_profile)

    cardinality, carrier, target =
      if first_unique && second_unique
        ['one-to-one', second_name, first_name]
      elsif first_unique
        ['many-to-one', second_name, first_name]
      elsif second_unique
        ['many-to-one', first_name, second_name]
      elsif relationship['status'] != 'wired'
        ['unresolved', nil, nil]
      elsif first_profile || second_profile
        ['many-to-many', nil, nil]
      else
        ['unknown', nil, nil]
      end

    {
      'first' => first_name,
      'second' => second_name,
      'keys' => relationship['keys'] || [],
      'source_status' => relationship['status'],
      'first_unique' => first_unique,
      'second_unique' => second_unique,
      'cardinality' => cardinality,
      'carrier' => carrier,
      'target' => target,
      'proof' => if relationship["#{first_unique ? 'first' : 'second'}_unique_proof"]
                   relationship["#{first_unique ? 'first' : 'second'}_unique_proof"]
                 elsif relationship["#{first_unique ? 'first' : 'second'}_db_unique"] == true
                   'tableau-db-unique'
                 elsif first_unique || second_unique
                   'warehouse-profile'
                 else
                   'required'
                 end
    }
  end

  def shared_hubs(objects, relations, profiles)
    safe_targets = relations.select { |r| %w[many-to-one one-to-one].include?(r['cardinality']) }
                            .group_by { |r| normalize(r['target']) }
    candidates = []
    safe_targets.each do |target, rows|
      next if rows.size < 2
      candidates << {
        'table' => objects.find { |name| normalize(name) == target } || target,
        'kind' => 'existing-object',
        'covers' => rows.map { |r| r['carrier'] }.uniq,
        'grain_keys' => key_set(rows.flat_map { |r| r['keys'].map(&:last) }),
        'evidence' => rows.map { |r| r['proof'] }.uniq
      }
    end
    profiles.each_value do |profile|
      covers = Array(profile['covers']).map(&:to_s)
      next unless profile['role'].to_s == 'dimension' && covers.size >= 2
      next unless unique_on?(profile, profile['grain_keys'])
      candidates << {
        'table' => profile['name'],
        'kind' => 'warehouse-candidate',
        'covers' => covers,
        'grain_keys' => key_set(profile['grain_keys']),
        'precomputed_fields' => Array(profile['precomputed_fields']),
        'refresh' => profile['refresh'],
        'evidence' => ['warehouse-profile']
      }
    end
    candidates.uniq { |candidate| normalize(candidate['table']) }
  end

  def primary_fact(facts, profiles, fallback)
    facts.max_by do |name|
      profile = profiles[normalize(name)] || {}
      [profile['row_count'].to_i, Array(profile['measures']).size]
    end || fallback
  end

  def orient_one_to_one!(relations, fact)
    root = normalize(fact)
    return if root.empty?

    adjacency = Hash.new { |hash, key| hash[key] = [] }
    relations.each do |relation|
      first = normalize(relation['first'])
      second = normalize(relation['second'])
      adjacency[first] << second
      adjacency[second] << first
    end
    distances = { root => 0 }
    queue = [root]
    until queue.empty?
      current = queue.shift
      adjacency[current].each do |neighbor|
        next if distances.key?(neighbor)
        distances[neighbor] = distances[current] + 1
        queue << neighbor
      end
    end

    relations.each do |relation|
      next unless relation['cardinality'] == 'one-to-one'
      first_distance = distances[normalize(relation['first'])]
      second_distance = distances[normalize(relation['second'])]
      next if first_distance.nil? || second_distance.nil? || first_distance == second_distance
      relation['carrier'], relation['target'] =
        if first_distance < second_distance
          [relation['first'], relation['second']]
        else
          [relation['second'], relation['first']]
        end
    end
  end

  def build(object_graph_plan, profiles: {}, field_map: {}, table_map: {}, reuse_dm_id: nil, join_plan: nil)
    raise Error, 'object-graph plan must contain datasources' unless object_graph_plan.is_a?(Hash) &&
                                                                  object_graph_plan['datasources'].is_a?(Array)
    object_graph_plan = apply_join_evidence(object_graph_plan, join_plan) if join_plan
    profiles = profile_index(profiles)
    datasource_plans = object_graph_plan['datasources'].map do |datasource|
      objects = Array(datasource['objects'])
      relations = Array(datasource['relationships']).map { |rel| relation_plan(rel, profiles) }
      unsafe = relations.select { |rel| %w[many-to-many unresolved].include?(rel['cardinality']) }
      unknown = relations.select { |rel| rel['cardinality'] == 'unknown' }
      facts = relations.select { |rel| rel['cardinality'] == 'many-to-one' }
                       .map { |rel| rel['carrier'] }.compact.uniq
      facts |= objects.select do |name|
        profile = profiles[normalize(name)] || {}
        profile['role'].to_s == 'fact' || datasource.dig('role_signals', name, 'name_role') == 'fact'
      end
      selected_fact = primary_fact(facts, profiles, datasource['fact_candidate'])
      orient_one_to_one!(relations, selected_fact)
      hubs = shared_hubs(objects, relations, profiles)
      mode = if reuse_dm_id
               'reuse-existing-dm'
             elsif unsafe.any?
               'remodeled-star'
             else
               'source-faithful'
             end
      blockers = []
      blockers << "#{unsafe.size} unsafe or unresolved relationship(s) require a unique hub or explicit replacement" if unsafe.any? && hubs.empty?
      blockers << "#{unknown.size} relationship(s) lack cardinality evidence; live join probes remain mandatory" if unknown.any?
      {
        'datasource' => datasource['datasource'],
        'caption' => datasource['caption'],
        'mode' => mode,
        'objects' => objects,
        'facts' => facts,
        'primary_fact' => selected_fact,
        'relationships' => relations,
        'shared_hub_candidates' => hubs,
        'blockers' => blockers
      }
    end

    substitutions = table_map.map do |source, target|
      profile = profiles[normalize(target)] || {}
      {
        'source' => source,
        'target' => target,
        'equivalence_proof' => profile['equivalence_proof'],
        'refresh' => profile['refresh']
      }
    end
    mode = reuse_dm_id ? 'reuse-existing-dm' :
      (datasource_plans.any? { |plan| plan['mode'] == 'remodeled-star' } ? 'remodeled-star' : 'source-faithful')
    {
      'schema_version' => VERSION,
      'generated_at' => Time.now.utc.iso8601,
      'mode' => mode,
      'accepted' => mode == 'source-faithful',
      'reuse_dm_id' => reuse_dm_id,
      'datasources' => datasource_plans,
      'table_profiles' => profiles.values,
      'table_mapping' => table_map,
      'field_mapping' => field_map,
      'substitutions' => substitutions,
      'required_proofs' => required_proofs(datasource_plans, substitutions)
    }
  end

  def required_proofs(datasource_plans, substitutions)
    proofs = []
    datasource_plans.each do |datasource|
      datasource['relationships'].each do |relationship|
        next if %w[many-to-one one-to-one].include?(relationship['cardinality'])
        proofs << {
          'kind' => 'target-uniqueness',
          'datasource' => datasource['datasource'],
          'relationship' => "#{relationship['first']}↔#{relationship['second']}",
          'status' => 'required'
        }
      end
    end
    substitutions.each do |substitution|
      next if valid_equivalence_proof?(substitution['equivalence_proof'])
      proofs << {
        'kind' => 'semantic-equivalence',
        'substitution' => "#{substitution['source']}→#{substitution['target']}",
        'status' => 'required'
      }
    end
    proofs
  end

  def accept!(plan, accepted_by:, reason:)
    raise Error, "unsupported mode #{plan['mode'].inspect}" unless MODES.include?(plan['mode'])
    raise Error, 'accepted-by is required' if accepted_by.to_s.strip.empty?
    raise Error, 'acceptance reason is required' if reason.to_s.strip.empty?
    plan['accepted'] = true
    plan['acceptance'] = {
      'accepted_by' => accepted_by,
      'reason' => reason,
      'accepted_at' => Time.now.utc.iso8601
    }
    plan
  end

  def valid_equivalence_proof?(proof)
    proof.is_a?(Hash) &&
      proof['match'] == true &&
      proof['before'].is_a?(Hash) &&
      proof['after'].is_a?(Hash) &&
      proof['probed_at'].to_s.match?(/\A\d{4}-\d{2}-\d{2}T/)
  end

  def validate!(plan, require_accepted: true)
    raise Error, "target-model plan schema must be #{VERSION}" unless plan['schema_version'].to_i == VERSION
    raise Error, "unsupported target-model mode #{plan['mode'].inspect}" unless MODES.include?(plan['mode'])
    if require_accepted && plan['mode'] != 'source-faithful' && plan['accepted'] != true
      raise Error, "#{plan['mode']} plan is not accepted; run plan-target-model.rb --accept ..."
    end
    Array(plan['datasources']).each do |datasource|
      if datasource['primary_fact'].to_s.empty? && datasource['mode'] != 'reuse-existing-dm'
        raise Error, "datasource #{datasource['caption'] || datasource['datasource']} has no primary_fact"
      end
      Array(datasource['relationships']).each do |relationship|
        next unless %w[many-to-one one-to-one].include?(relationship['cardinality'])
        if relationship['carrier'].to_s.empty? || relationship['target'].to_s.empty?
          raise Error, "safe relationship #{relationship['first']}↔#{relationship['second']} lacks carrier/target"
        end
        endpoints = [normalize(relationship['first']), normalize(relationship['second'])].sort
        direction = [normalize(relationship['carrier']), normalize(relationship['target'])].sort
        unless endpoints == direction && normalize(relationship['carrier']) != normalize(relationship['target'])
          raise Error, "relationship #{relationship['first']}↔#{relationship['second']} has invalid carrier/target"
        end
        unless %w[tableau-db-unique warehouse-profile join-plan].include?(relationship['proof'])
          raise Error, "relationship #{relationship['carrier']}→#{relationship['target']} lacks uniqueness evidence"
        end
      end
      unresolved = Array(datasource['relationships']).select do |relationship|
        %w[many-to-many unresolved].include?(relationship['cardinality'])
      end
      if plan['mode'] == 'remodeled-star' && unresolved.any?
        raise Error, "datasource #{datasource['caption'] || datasource['datasource']} still has " \
                     "#{unresolved.size} unsafe relationship(s); choose a unique hub/replacement before acceptance"
      end
    end
    Array(plan['substitutions']).each do |substitution|
      proof = substitution['equivalence_proof']
      raise Error, "substitution #{substitution['source']}→#{substitution['target']} lacks a matching equivalence proof" \
        unless valid_equivalence_proof?(proof)
      if Array((profile_index(plan['table_profiles']) || {})[normalize(substitution['target'])]&.dig('precomputed_fields')).any? &&
         substitution['refresh'].to_s.empty?
        raise Error, "precomputed target #{substitution['target']} lacks refresh lineage"
      end
    end
    true
  end

  def semantic_edit_entries(plan)
    Array(plan['substitutions']).map do |substitution|
      {
        'edit_description' => "target-model substitution #{substitution['source']}→#{substitution['target']}",
        'claim' => 'approved target table is grain- and measure-equivalent to the Tableau source',
        'grain' => Array(substitution.dig('equivalence_proof', 'grain')),
        'measures' => Array(substitution.dig('equivalence_proof', 'measures')),
        'proof' => substitution['equivalence_proof'],
        'source' => 'target-model-plan'
      }
    end
  end

  def converter_options(plan)
    validate!(plan)
    rows = profile_index(plan['table_profiles']).each_with_object({}) do |(_key, profile), out|
      next if profile['row_count'].nil?
      out[profile['name']] = profile['row_count']
    end
    {
      'table_row_counts' => rows,
      'model_plan' => plan
    }
  end
end
