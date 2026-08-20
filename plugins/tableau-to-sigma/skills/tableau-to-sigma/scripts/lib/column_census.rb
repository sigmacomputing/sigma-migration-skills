# Post-readback column census (fix-workstream G).
#
# WHY: a live migration POSTed a data-model spec with hundreds of columns and
# the live DM resolved only a fraction of them — the rest silently disappeared
# (no HTTP error, no type="error" entries for the dropped ones). The existing
# post-and-readback type=error guard only catches columns that EXIST in the
# readback with a broken type; it cannot see columns that are simply GONE.
# This census compares what was POSTed against what the readback actually
# resolved, per element, and turns a silent drop into a loud abort.
#
# Pure functions only — no HTTP, no filesystem — so the logic is fully
# testable offline (scripts/test-column-census.rb). post-and-readback.rb wires
# it to the live readback on the DM path and exits 2 on any discrepancy.

require 'set'

module ColumnCensus
  module_function

  # Compare a posted spec against its readback.
  #
  #   posted_spec     — the Hash that was POSTed ({pages:[{elements:[
  #                     {id, name, columns:[{name,...}], metrics:[...]}]}]})
  #   readback_spec   — the Hash from GET .../spec after POST (server-assigned
  #                     element ids; element NAMES survive the round trip, ids
  #                     may not — DM POST reassigns them)
  #   columns_entries — entries from GET .../columns
  #                     ([{elementId, columnId, label, formula, type:{type}}])
  #
  # Returns an Array of per-element discrepancy Hashes (empty == clean):
  #   { 'element' => name,
  #     'posted_columns' => N, 'resolved_columns' => M,
  #     'missing_columns' => [posted column names absent from /columns],
  #     'posted_metrics' => N, 'resolved_metrics' => M,
  #     'missing_metrics' => [posted metric names absent from readback metrics[]],
  #     'error_columns' => [readback labels whose type compiled to "error"],
  #     'note' => optional }
  # Legacy posted/resolved/missing aliases describe COLUMNS only.
  def census(posted_spec, readback_spec, columns_entries)
    labels_by_el = Hash.new { |h, k| h[k] = [] }
    errors_by_el = Hash.new { |h, k| h[k] = [] }
    (columns_entries || []).each do |c|
      next unless c['elementId'] && c['label']
      labels_by_el[c['elementId']] << c['label']
      errors_by_el[c['elementId']] << c['label'] if c.dig('type', 'type') == 'error'
    end

    rb_ids_by_name = Hash.new { |h, k| h[k] = [] }
    rb_ids = Set.new
    metrics_by_el = Hash.new { |h, k| h[k] = [] }
    flatten_elements(readback_spec).each do |e|
      rb_ids << e['id'] if e['id']
      rb_ids_by_name[e['name']] << e['id'] if e['name'] && e['id']
      metrics_by_el[e['id']].concat(Array(e['metrics']).map do |metric|
        metric.is_a?(Hash) ? metric['name'] : metric
      end.compact) if e['id']
    end

    problems = []
    flatten_elements(posted_spec).each do |pel|
      posted_columns = Array(pel['columns']).map { |column| column['name'] }.compact
      posted_metrics = Array(pel['metrics']).map { |metric| metric['name'] }.compact
      next if posted_columns.empty? && posted_metrics.empty?

      # Match by NAME first (ids are reassigned on DM POST), then by id.
      server_ids = rb_ids_by_name[pel['name']]
      server_ids = [pel['id']] if server_ids.empty? && rb_ids.include?(pel['id'])

      if server_ids.empty?
        problems << { 'element' => pel['name'] || pel['id'] || '?',
                      'posted' => posted_columns.size, 'resolved' => 0,
                      'missing' => posted_columns,
                      'posted_columns' => posted_columns.size, 'resolved_columns' => 0,
                      'missing_columns' => posted_columns,
                      'posted_metrics' => posted_metrics.size, 'resolved_metrics' => 0,
                      'missing_metrics' => posted_metrics, 'error_columns' => [],
                      'note' => 'element missing from readback entirely' }
        next
      end

      resolved_columns = server_ids.flat_map { |sid| labels_by_el[sid] }
      resolved_metrics = server_ids.flat_map { |sid| metrics_by_el[sid] }.uniq
      err_cols = server_ids.flat_map { |sid| errors_by_el[sid] }.uniq
      resolved_set = resolved_columns.to_set
      # Sigma relabels joined-dim columns with a disambiguation suffix —
      # "Customer Id" may read back as "Customer Id (CUSTOMER_DIM)". Accept
      # the suffixed label as a resolution of the posted name.
      desuffixed = resolved_columns.map { |label| label.sub(/ \([^()]*\)\z/, '') }.to_set
      missing_columns = posted_columns.reject do |name|
        resolved_set.include?(name) || desuffixed.include?(name)
      end
      resolved_metrics_set = resolved_metrics.to_set
      missing_metrics = posted_metrics.reject { |name| resolved_metrics_set.include?(name) }

      next if missing_columns.empty? && missing_metrics.empty? && err_cols.empty?
      problems << { 'element' => pel['name'] || pel['id'] || '?',
                    'posted' => posted_columns.size, 'resolved' => resolved_columns.size,
                    'missing' => missing_columns,
                    'posted_columns' => posted_columns.size,
                    'resolved_columns' => resolved_columns.size,
                    'missing_columns' => missing_columns,
                    'posted_metrics' => posted_metrics.size,
                    'resolved_metrics' => resolved_metrics.size,
                    'missing_metrics' => missing_metrics,
                    'error_columns' => err_cols }
    end
    problems
  end

  # Human report, one block per problem element. Missing-name lists are capped
  # at +cap+ names (default 20) with an "... and K more" tail.
  def report_lines(problems, cap: 20)
    problems.flat_map do |p|
      head = "#{p['element']}: posted #{p['posted']} column(s), readback resolved #{p['resolved']}"
      if p['posted_metrics'].to_i.positive? || p['missing_metrics']&.any?
        head += "; posted #{p['posted_metrics']} metric(s), readback spec resolved #{p['resolved_metrics']}"
      end
      head += " — #{p['note']}" if p['note']
      lines = [head]
      if (m = p['missing_columns'] || p['missing']).any?
        shown = m.first(cap).join(', ')
        tail = m.size > cap ? " ... and #{m.size - cap} more" : ''
        lines << "  missing columns #{m.size}: #{shown}#{tail}"
      end
      if (m = p['missing_metrics'] || []).any?
        shown = m.first(cap).join(', ')
        tail = m.size > cap ? " ... and #{m.size - cap} more" : ''
        lines << "  missing metrics #{m.size}: #{shown}#{tail}"
      end
      if (e = p['error_columns']).any?
        lines << "  type=error #{e.size}: #{e.first(cap).join(', ')}#{e.size > cap ? " ... and #{e.size - cap} more" : ''}"
      end
      lines
    end
  end

  def posted_column_count(posted_spec)
    flatten_elements(posted_spec)
      .sum { |element| Array(element['columns']).count { |column| column['name'] } }
  end

  def posted_metric_count(posted_spec)
    flatten_elements(posted_spec)
      .sum { |element| Array(element['metrics']).count { |metric| metric['name'] } }
  end

  def flatten_elements(spec)
    return [] unless spec.is_a?(Hash)
    (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
  end
end
