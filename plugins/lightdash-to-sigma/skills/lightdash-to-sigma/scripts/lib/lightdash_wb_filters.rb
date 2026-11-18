# frozen_string_literal: true
# Filter handling for build-lightdash-workbook.rb, mixed into LightdashWorkbook::Builder:
# chart-level metricQuery.filters -> element filters, metricQuery.limit -> top-N, and the
# dashboard-filter -> control shape table.
#
#   equals / in -> list include        notEquals / notIn -> list exclude
#   isNull / notNull -> ledger gap (a null-valued list filter shape is unverified)
#   greaterThan / lessThan / inBetween -> number-range (numbers) or date-range (dates)
#   everything else -> ledger gap (list controls are still offered unfiltered)
#
# Ruby 2.6-compatible, stdlib only.

module LightdashWbFilters
  LF = LightdashFormula

    # --- chart-level filters -> element filters -----------------------------------
    def apply_filters(el, mq, hash, slug)
      f = mq['filters']
      return unless f.is_a?(Hash) || f.is_a?(Array)
      rules = []
      collect_rules(f.is_a?(Hash) ? f['dimensions'] : f, rules, slug)
      mgroup = f.is_a?(Hash) ? f['metrics'] : nil
      if filter_present?(mgroup)
        gap!('scope-cut', "chart #{slug}: metric filter", 'filters on aggregated metrics (HAVING) are not translated')
      end
      tgroup = f.is_a?(Hash) ? f['tableCalculations'] : nil
      if filter_present?(tgroup)
        gap!('scope-cut', "chart #{slug}: table calculation filter", 'filters on table calculations are not translated')
      end
      used = {}
      rules.each do |rule|
        next if rule.nil?
        fid = rule.dig('target', 'fieldId').to_s
        begin
          col = dim_col(el, fid)
        rescue LightdashWorkbook::Missing => e
          gap!('scope-cut', "chart #{slug}: filter on #{fid}", e.message)
          next
        end
        if used[col['id']]
          gap!('scope-cut', "chart #{slug}: filter on #{fid}", 'a second filter on the same column is not expressible (Sigma allows one element filter per column)')
          next
        end
        filt, why = element_filter(rule, @fm[fid], col)
        if filt.nil?
          gap!('scope-cut', "chart #{slug}: filter on #{fid}", why)
          next
        end
        used[col['id']] = true
        (hash['filters'] ||= []) << filt.merge('id' => "#{hash['id']}-f-#{hash['filters'].length + 1}", 'columnId' => col['id'])
      end
    end

    # Flatten and/or groups into a rule list. An `or` group of same-field equals rules
    # becomes one list rule; any other `or` is a gap.
    def collect_rules(group, out, slug)
      if group.is_a?(Array)
        group.each { |g| collect_rules(g, out, slug) }
        return
      end
      return unless group.is_a?(Hash)
      if group['target']
        out << group
        return
      end
      Array(group['and']).each { |g| collect_rules(g, out, slug) }
      return unless group['or']
      items = Array(group['or'])
      leaves = items.select { |i| i.is_a?(Hash) && i['target'] }
      same = leaves.length == items.length && leaves.map { |l| [l.dig('target', 'fieldId'), l['operator']] }.uniq.length == 1 &&
             %w[equals notEquals].include?(leaves.first['operator'].to_s)
      if same && leaves.first['operator'].to_s == 'equals'
        out << leaves.first.merge('values' => leaves.flat_map { |l| Array(l['values']) })
      else
        gap!('scope-cut', "chart #{slug}: OR filter", 'OR-combined filter groups are not translated')
      end
    end

    def filter_present?(group)
      group.respond_to?(:empty?) ? !group.empty? : !group.nil?
    end

    def coerce(v, type)
      case type.to_s
      when 'number'
        return v if v.is_a?(Numeric)
        s = v.to_s
        s =~ /\A-?\d+\z/ ? s.to_i : (s =~ /\A-?\d*\.\d+\z/ ? s.to_f : v)
      when 'boolean'
        v.to_s.downcase == 'true' ? true : (v.to_s.downcase == 'false' ? false : v)
      else v
      end
    end

    def iso(v)
      return v.utc.strftime('%Y-%m-%dT%H:%M:%SZ') if v.is_a?(Time)
      return v.strftime('%Y-%m-%dT00:00:00Z') if v.respond_to?(:strftime)
      s = v.to_s.strip
      return "#{s}T00:00:00Z" if s =~ /\A\d{4}-\d{2}-\d{2}\z/
      Time.parse(s).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    rescue ArgumentError
      nil
    end

    def date_type?(fm)
      %w[date timestamp].include?(fm['type'].to_s) || fm['kind'] == 'interval'
    end

    # -> [filter hash (without id/columnId), nil] | [nil, reason]
    def element_filter(rule, fm, _col)
      op = rule['operator'].to_s
      vals = Array(rule['values'])
      type = fm['type']
      case op
      when 'equals', 'in'
        return [nil, 'equals filter has no values'] if vals.empty?
        [{ 'kind' => 'list', 'mode' => 'include', 'values' => vals.map { |v| coerce(v, type) } }, nil]
      when 'notEquals', 'notIn'
        return [nil, 'notEquals filter has no values'] if vals.empty?
        [{ 'kind' => 'list', 'mode' => 'exclude', 'values' => vals.map { |v| coerce(v, type) } }, nil]
      when 'isNull', 'notNull'
        # no repo builder emits a null-valued list filter; ledgered instead of guessing the shape
        [nil, "#{op} has no verified Sigma element-filter shape (a list filter with a null value is unverified)"]
      when 'greaterThan', 'lessThan', 'inBetween'
        range_filter(op, vals, fm)
      else [nil, "filter operator #{op.inspect} is not translated"]
      end
    end

    def range_filter(op, vals, fm)
      if date_type?(fm)
        d = vals.map { |v| iso(v) }
        return [nil, "#{op} filter has unparseable date value(s) #{vals.inspect}"] if d.empty? || d.any?(&:nil?)
        case op
        when 'greaterThan' then [{ 'kind' => 'date-range', 'mode' => 'after', 'date' => d.first, 'includeNulls' => 'when-no-value-is-selected' }, nil]
        when 'lessThan' then [{ 'kind' => 'date-range', 'mode' => 'before', 'date' => d.first, 'includeNulls' => 'when-no-value-is-selected' }, nil]
        else
          return [nil, 'inBetween filter needs two dates'] if d.length < 2
          [{ 'kind' => 'date-range', 'mode' => 'between', 'startDate' => d[0], 'endDate' => d[1], 'includeNulls' => 'when-no-value-is-selected' }, nil]
        end
      elsif fm['type'].to_s == 'number'
        n = vals.map { |v| coerce(v, 'number') }
        return [nil, "#{op} filter has non-numeric value(s) #{vals.inspect}"] if n.empty? || n.any? { |v| !v.is_a?(Numeric) }
        f = { 'kind' => 'number-range', 'includeNulls' => 'when-no-value-is-selected' }
        case op
        when 'greaterThan' then f['min'] = n.first
        when 'lessThan' then f['max'] = n.first
        else
          return [nil, 'inBetween filter needs two numbers'] if n.length < 2
          f['min'] = n[0]
          f['max'] = n[1]
        end
        gap!('quality-waiver', "filter #{fm['name']}", "#{op} is strict in Lightdash; Sigma number-range bounds are inclusive") if op != 'inBetween'
        [f, nil]
      else
        [nil, "#{op} on a #{fm['type']} field is not translated"]
      end
    end

    # --- chart limit -> top-n -----------------------------------------------------
    def apply_limit(el, mq, hash, slug)
      limit = mq['limit']
      return if limit.nil? || hash['kind'] == 'kpi-chart'
      return if Array(mq['dimensions']).empty?
      s = Array(mq['sorts']).first
      sc = s && el.by_key[s['fieldId']]
      fm = s && @fm[s['fieldId']]
      metric_sort = sc && ((fm && fm['kind'] == 'metric') || custom_metric(el.chart, s['fieldId']))
      # Shape emitted by looker (build_workbook.py top-n) and domo (build-workbook.rb) against
      # table-sourced elements: rank / mode top-n / rowCount / includeNulls. Only descending
      # (top-n) sorts are emitted, as domo does; ascending (bottom-n) is ledgered, unverified.
      if metric_sort && hash['kind'] != 'pivot-table' && s['descending'] == true
        (hash['filters'] ||= []) << { 'id' => "#{hash['id']}-f-#{hash['filters'].length + 1}", 'columnId' => sc['id'], 'kind' => 'top-n',
                                      'rankingFunction' => 'rank', 'mode' => 'top-n',
                                      'rowCount' => limit.to_i, 'includeNulls' => 'when-no-value-is-selected' }
      elsif limit.to_i >= LightdashWorkbook::LIGHTDASH_DEFAULT_LIMIT && !(s && fm && fm['kind'] == 'metric')
        warn!("chart #{slug}: row limit #{limit} (Lightdash default cap) not applied")
      else
        gap!('quality-waiver', "chart #{slug}", "row limit #{limit} not applied (only a descending metric-sorted chart gets a top-N filter)")
      end
    end

    # -> [controlType, attrs, note] | [nil, nil, reason]. `note` set = built unfiltered.
    def control_shape(flt, fm)
      op = flt['operator']
      vals = flt['values']
      type = fm['type']
      off = flt['disabled']
      case op
      when 'equals', 'notEquals'
        v = off ? [] : vals.map { |x| coerce(x, type) }
        return ['list', { 'mode' => op == 'equals' ? 'include' : 'exclude', 'selectionMode' => 'multiple', 'values' => v }, nil]
      when 'greaterThan', 'lessThan', 'inBetween'
        if date_type?(fm)
          d = vals.map { |x| iso(x) }
          if off || d.empty? || d.any?(&:nil?) || (op == 'inBetween' && d.length < 2)
            return ['date-range', { 'mode' => 'between', 'includeNulls' => 'when-no-value-is-selected' }, nil] if off
            return [nil, nil, "#{op} date value(s) #{vals.inspect} unparseable"]
          end
          return ['date-range', { 'mode' => 'after', 'date' => d.first, 'includeNulls' => 'when-no-value-is-selected' }, nil] if op == 'greaterThan'
          return ['date-range', { 'mode' => 'before', 'date' => d.first, 'includeNulls' => 'when-no-value-is-selected' }, nil] if op == 'lessThan'
          return ['date-range', { 'mode' => 'between', 'startDate' => d[0], 'endDate' => d[1], 'includeNulls' => 'when-no-value-is-selected' }, nil]
        elsif type.to_s == 'number'
          n = vals.map { |x| coerce(x, 'number') }
          return ['number-range', {}, nil] if off
          return [nil, nil, "#{op} numeric value(s) #{vals.inspect} invalid"] if n.empty? || n.any? { |x| !x.is_a?(Numeric) } || (op == 'inBetween' && n.length < 2)
          a = {}
          case op
          when 'greaterThan' then a['low'] = n.first
          when 'lessThan' then a['high'] = n.first
          else
            a['low'] = n[0]
            a['high'] = n[1]
          end
          return ['number-range', a, nil]
        end
      end
      # unmappable operator: a list control can still be offered unfiltered; others are skipped
      if date_type?(fm) || type.to_s == 'number' && %w[greaterThan lessThan inBetween].include?(op)
        return [nil, nil, "operator #{op.inspect} on a #{type} field has no Sigma control equivalent"]
      end
      ['list', { 'mode' => 'include', 'selectionMode' => 'multiple', 'values' => [] }, "operator #{op.inspect} (values #{vals.inspect}) has no Sigma control equivalent"]
    end
end
