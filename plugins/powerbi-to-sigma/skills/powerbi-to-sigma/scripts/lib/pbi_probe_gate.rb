# frozen_string_literal: true

# Glue between migrate-powerbi.rb --probe-sources and scripts/probe-native-sources.py.
#
# WHY. A Custom SQL (NativeQuery) element used to be discovered one POST 400 at a
# time: a bound column the SQL does not return, a boolean the warehouse hands back as
# VARCHAR 'True'/'False', an output name the converter output guessed wrong. The probe
# runs every distinct statement ONCE (columns + warehouse types) before anything is
# written to Sigma. This module turns its report into the three things the
# orchestrator needs, all pure and unit-tested offline:
#
#   * sql_output_names(report)  -> the <WORK>/sql-output-names.json shape that
#                                  PbiDmResolver consumes ({"Element" => ["SQL output", ..]}),
#                                  so an unknown [Custom SQL/X] is nulled before the POST
#   * apply_casts!(dm, report)  -> folds the casts the probe reports for TMSL-vs-warehouse
#                                  type mismatches (VARCHAR 'True'/'False' -> TRY_TO_BOOLEAN,
#                                  ...) into the element SQL
#   * blockers(report)          -> the bound columns that are missing from the SQL output
#                                  (or still ambiguous), which STOP the run
#
# Ruby 2.6 floor: no filter_map / tally / except / endless defs.
require 'digest'
require 'json'
require_relative 'pbi_dm_resolver'

module PbiProbeGate
  module_function

  CUSTOM_SQL_REF = %r{\[Custom SQL/([^\]]+)\]}.freeze

  # The probe script's --dialect values; anything else (or unknown) probes as Snowflake.
  def dialect_for(wh_type)
    t = wh_type.to_s.downcase
    return 'databricks' if t.include?('databricks') || t.include?('spark')
    return 'bigquery' if t.include?('bigquery')

    'snowflake'
  end

  # The Enter-data (Table.FromRows) SQL dialect handed to extract-model-pbix.py --dialect. Unlike
  # the probe (which only ever runs on a Sigma connection), this SQL runs on the CUSTOMER's
  # warehouse, so an unknown warehouse must never silently get Snowflake syntax:
  #   snowflake / databricks / bigquery -> themselves        (unset -> snowflake, the historic default)
  #   postgres / redshift               -> 'ansi'            (DOUBLE PRECISION, quoted identifiers)
  #   anything else (synapse, sql server, mysql, ...) -> 'unsupported': the extractor leaves the
  #   Enter-data partition as extracted and records a loud note instead of emitting SQL that fails.
  def extract_dialect_for(wh_type)
    t = wh_type.to_s.downcase.strip
    return 'snowflake' if t.empty? || t.include?('snowflake')
    return 'databricks' if t.include?('databricks') || t.include?('spark')
    return 'bigquery' if t.include?('bigquery')
    return 'ansi' if t.include?('postgres') || t.include?('redshift')

    'unsupported'
  end

  def elements(dm)
    (dm['pages'] || []).flat_map { |p| p['elements'] || [] }
  end

  # Custom SQL elements the probe would check: kind sql, a statement, and at least one
  # [Custom SQL/X] column reference (mirrors probe-native-sources.py sql_elements).
  def sql_elements(dm)
    elements(dm).select do |e|
      src = e['source'] || {}
      src['kind'] == 'sql' && !src['statement'].to_s.strip.empty? &&
        (e['columns'] || []).any? { |c| c['formula'].to_s =~ CUSTOM_SQL_REF }
    end
  end

  # The argv for the probe script (the caller prepends the python launcher). With
  # probe_results the captured results are replayed and nothing touches the warehouse.
  def command(script, dm_path:, tmsl_path:, out_path:, state_path:, connection:, folder:, dialect:,
              probe_results: nil, cache_max_age_hours: nil)
    argv = [script, '--dm', dm_path, '--tmsl', tmsl_path, '--out', out_path, '--dialect', dialect]
    if probe_results
      argv + ['--probe-results', probe_results]
    else
      argv += ['--connection-id', connection.to_s, '--folder-id', folder.to_s, '--state', state_path]
      argv += ['--probe-cache-max-age-hours', cache_max_age_hours.to_s] if cache_max_age_hours
      argv
    end
  end

  # { "Element name" => short sha256 of its Custom SQL statement } for every probed element. Stored
  # beside sql-output-names.json so a LATER run without --probe-sources can tell whether a probed
  # output list still describes the statement the model has now.
  def statement_stamps(dm)
    out = {}
    sql_elements(dm).each do |e|
      out[e['name'].to_s] = Digest::SHA256.hexdigest(e.dig('source', 'statement').to_s.strip)[0, 16]
    end
    out
  end

  # Drops the probed output names whose element statement changed (or whose element is gone) since
  # the stamp was written. With no stamp (nil) the file is a hand-supplied input and is honored.
  # Returns [fresh_names, dropped_element_names].
  def fresh_sql_names(names, stamps, dm)
    names ||= {}
    return [names, []] if stamps.nil?

    now = statement_stamps(dm)
    kept = {}
    dropped = []
    names.each do |el, cols|
      if stamps[el] && now[el] && stamps[el] == now[el]
        kept[el] = cols
      else
        dropped << el
      end
    end
    [kept, dropped]
  end

  # { "Element name" => ["SQL output", ...] } for every element whose statement was
  # probed successfully. An element whose probe failed contributes nothing (the resolver
  # then leaves its [Custom SQL/X] refs alone rather than nulling them on no evidence).
  def sql_output_names(report)
    out = {}
    ((report || {})['elements'] || []).each do |e|
      cols = e['output_columns']
      next unless e['name'] && cols.is_a?(Array) && !cols.empty?

      out[e['name']] = cols.map(&:to_s)
    end
    out
  end

  # Bound columns that make the run STOP: [Custom SQL/X] references the statement's
  # output does not contain (status missing), and output names still containing "/"
  # (ambiguous in Sigma). A case-only difference is NOT a blocker (the resolver rewrites
  # it to the exact name). Each entry: {element, column, ref, status, suggestions}.
  # The single SQL output name the dm-resolver would rewrite a missing ref to (its nk
  # key matches exactly one output name), or nil.
  def resolver_fix(element, bound)
    return nil unless bound['status'] == 'missing'

    want = PbiDmResolver.nk(bound['ref'])
    cands = Array(element['output_columns']).map(&:to_s).select { |o| PbiDmResolver.nk(o) == want }.uniq
    cands.size == 1 ? cands[0] : nil
  end

  # Missing refs the resolver fixes by itself (not blockers):
  # {element, column, ref, status: 'resolver-fixable', fixes_to}.
  def resolver_fixable(report)
    out = []
    ((report || {})['elements'] || []).each do |e|
      (e['bound'] || []).each do |b|
        to = resolver_fix(e, b)
        next unless to

        out << { 'element' => e['name'], 'column' => b['column'], 'ref' => b['ref'],
                 'status' => 'resolver-fixable', 'fixes_to' => to }
      end
    end
    out
  end

  def blockers(report, allow_missing: false)
    out = []
    ((report || {})['elements'] || []).each do |e|
      (e['bound'] || []).each do |b|
        next unless %w[missing ambiguous-slash].include?(b['status'])
        next if allow_missing && b['status'] == 'missing'
        next if resolver_fix(e, b)

        out << { 'element' => e['name'], 'column' => b['column'], 'ref' => b['ref'],
                 'status' => b['status'], 'suggestions' => b['suggestions'] || [] }
      end
    end
    out
  end

  # Elements whose statement could not be probed at all (warehouse error, no result).
  def probe_errors(report)
    ((report || {})['elements'] || []).select { |e| e['status'] == 'probe-error' }
                                      .map { |e| { 'element' => e['name'], 'error' => e['error'].to_s } }
  end

  # The multi-line STOP message for the orchestrator (printed before exit 10).
  def stop_message(blocks, report_path)
    lines = []
    lines << '╭─ STOP — Custom SQL does not return the columns the model binds ─'
    blocks.first(30).each do |b|
      what = if b['status'] == 'ambiguous-slash'
               "output name #{b['ref'].inspect} contains '/' (alias it without '/')"
             else
               "[Custom SQL/#{b['ref']}] is not in the SQL output" +
                 (b['suggestions'].empty? ? '' : " (did you mean #{b['suggestions'].join(', ')}?)")
             end
      lines << "│  • #{b['element']} / #{b['column']}: #{what}"
    end
    lines << "│  ... and #{blocks.size - 30} more (see #{report_path})" if blocks.size > 30
    lines << '│'
    lines << '│  Posting this data model would fail (or bind a Null column). Fix the SQL or the'
    lines << '│  model column, then rerun. If you fixed it ON THE WAREHOUSE (added a column to the'
    lines << '│  view, same SQL text), the cached probe result is stale: rerun with --probe-no-cache'
    lines << '│  (or --probe-cache-max-age-hours N; results older than 24h are re-probed anyway).'
    lines << '│  To go on anyway and let the resolver null the unresolved bindings, rerun with'
    lines << '│  --probe-allow-missing.'
    lines << "│  Full report: #{report_path}"
    lines << '╰──────────────────────────────────────────────────────────────────────────────'
    lines.join("\n")
  end

  # Applies the report's patched statements (the original SQL wrapped in a SELECT that casts
  # each mismatched column, output names unchanged) to the matching elements of `dm`.
  # Returns the casts that were applied: [{element, column, expression, tmsl_type, warehouse_type}].
  def apply_casts!(dm, report)
    patched = (report || {})['patched_statements'] || {}
    return [] if patched.empty?

    applied_ids = {}
    elements(dm).each do |e|
      next unless e.dig('source', 'kind') == 'sql'

      stmt = patched[e['id']]
      next unless stmt

      e['source']['statement'] = stmt
      applied_ids[e['id']] = e['name']
    end
    ((report || {})['casts'] || []).select { |c| applied_ids.key?(c['element_id']) }.map do |c|
      { 'element' => applied_ids[c['element_id']], 'column' => c['column'], 'expression' => c['expression'],
        'tmsl_type' => c['tmsl_type'], 'warehouse_type' => c['warehouse_type'], 'kind' => c['kind'] }
    end
  end

  # One-line summary for the run log.
  def summary_line(report, applied)
    s = (report || {})['summary'] || {}
    "probe-sources: #{s['elements_probed'] || 0} Custom SQL element(s), #{s['bound_columns'] || 0} bound column(s), " \
      "#{s['missing_columns'] || 0} missing, #{s['case_only_matches'] || 0} case-only, #{applied.size} cast(s) applied, " \
      "#{s['type_warnings'] || 0} type warning(s), #{s['probe_errors'] || 0} probe error(s)"
  end
end
