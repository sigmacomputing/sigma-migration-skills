# frozen_string_literal: true
# Column construction for build-lightdash-workbook.rb: Lightdash fieldIds -> columns on a
# chart element sourced from the DM explore element. Mixed into LightdashWorkbook::Builder
# (needs @fm field-map, @dm_el / @dm_name, gap!, sanitize, source).
#
#   dimensions / intervals   [<DM element name>/<field-map name>]
#   DM metrics               [Metrics/<field-map name>]  (inline: true -> the DM aggregate with
#                            every ref prefixed by the DM element name; used by kpi-chart)
#   additionalMetrics        aggregate over the base column via LightdashFormula.aggregate_formula
#   tableCalculations        only simple arithmetic over ${table.field} / ${calc}; anything else
#                            raises Missing with the original SQL quoted
#
# Ruby 2.6-compatible, stdlib only.

module LightdashWbColumns
  LF = LightdashFormula

    # Column ref on the chart's source table. The source (master or base table) is only known
    # at emit time, so the prefix is a placeholder that emit rewrites.
    def ref(name)
      "[#{LightdashWorkbook::SRC}/#{name}]"
    end

    # --- column construction -------------------------------------------------
    def inline_metric(fm)
      m = (@dm_el['metrics'] || []).find { |x| x['id'] == fm['metric_id'] }
      raise LightdashWorkbook::Missing, "metric #{fm['name']} not found on the DM explore element" unless m
      m['formula'].to_s.gsub(%r{\[([^\]/]+)\]}) { "[#{LightdashWorkbook::SRC}/#{Regexp.last_match(1)}]" }
    end

    def clean(h)
      h.reject { |_, v| v.nil? }
    end

    def dim_col(el, fid)
      return el.by_key[fid] if el.by_key[fid]
      fm = @fm[fid]
      raise LightdashWorkbook::Missing, "field #{fid} is not in field-map.json" unless fm
      raise LightdashWorkbook::Missing, "field #{fid} was skipped by the data model (#{fm['reason']})" if fm['kind'] == 'skipped'
      raise LightdashWorkbook::Missing, "field #{fid} is a metric, not a dimension" if fm['kind'] == 'metric'
      el.add(fid, clean('id' => "#{el.id}-c-#{sanitize(fid)}", 'name' => fm['name'], 'formula' => ref(fm['name']),
                        'format' => fm['format']))
    end

    def metric_col(el, fid, inline: false)
      return el.by_key[fid] if el.by_key[fid]
      fm = @fm[fid]
      return custom_metric_col(el, fid) if fm.nil? && custom_metric(el.chart, fid)
      raise LightdashWorkbook::Missing, "field #{fid} is not in field-map.json" unless fm
      raise LightdashWorkbook::Missing, "field #{fid} was skipped by the data model (#{fm['reason']})" if fm['kind'] == 'skipped'
      return dim_col(el, fid) unless fm['kind'] == 'metric'
      formula = inline ? inline_metric(fm) : "[Metrics/#{fm['name']}]"
      el.add(fid, clean('id' => "#{el.id}-c-#{sanitize(fid)}", 'name' => fm['name'], 'formula' => formula, 'format' => fm['format']))
    end

    def custom_metric(chart, fid)
      Array(chart.dig('metricQuery', 'additionalMetrics')).find do |m|
        m.is_a?(Hash) && "#{m['table']}_#{m['name']}" == fid
      end
    end

    def table_calc(chart, name)
      Array(chart.dig('metricQuery', 'tableCalculations')).find { |c| c.is_a?(Hash) && c['name'].to_s == name }
    end

    def custom_metric_col(el, fid)
      return el.by_key[fid] if el.by_key[fid]
      m = custom_metric(el.chart, fid)
      raise LightdashWorkbook::Missing, "custom metric #{fid} not found" unless m
      if m['generationType'].to_s == 'periodOverPeriod'
        raise LightdashWorkbook::Missing, "custom metric #{m['name']} is a period-over-period metric (no Sigma equivalent)"
      end
      base = m['baseDimensionName'].to_s
      if base.empty?
        sql = m['sql'].to_s.strip
        base = Regexp.last_match(1) if sql =~ /\A\$\{TABLE\}\.([A-Za-z0-9_]+)\z/
      end
      raise LightdashWorkbook::Missing, "custom metric #{m['name']}: only metrics over a single column are translated (sql #{m['sql'].to_s.inspect})" if base.to_s.empty?
      base_fm = @fm["#{m['table']}_#{base}"]
      raise LightdashWorkbook::Missing, "custom metric #{m['name']}: base field #{m['table']}_#{base} is not mapped" if base_fm.nil? || base_fm['kind'] == 'skipped'
      pred = nil
      Array(m['filters']).each do |f|
        pred = custom_metric_pred(m, f, pred)
      end
      formula, why = LF.aggregate_formula(m['type'], ref(base_fm['name']), pred: pred, percentile: m['percentile'])
      raise LightdashWorkbook::Missing, "custom metric #{m['name']}: #{why}" unless formula
      label = m['label'].to_s.empty? ? LF.titleize(m['name']) : m['label'].to_s
      el.add(fid, clean('id' => "#{el.id}-c-#{sanitize(fid)}", 'name' => label, 'formula' => formula,
                        'format' => LF.sigma_format(m['format'], type: 'number')))
    end

    def custom_metric_pred(metric, filt, prev)
      target = filt.dig('target', 'fieldRef').to_s.split('.').last
      fm = @fm["#{metric['table']}_#{target}"]
      raise LightdashWorkbook::Missing, "custom metric #{metric['name']}: filter field #{target.inspect} is not mapped" if fm.nil? || fm['kind'] == 'skipped'
      vals = Array(filt['values']).map { |v| LF.literal(v, fm['type']) }
      clause =
        case filt['operator'].to_s
        when 'equals' then vals.length == 1 ? "#{ref(fm['name'])} = #{vals.first}" : "In(#{ref(fm['name'])}, #{vals.join(', ')})"
        when 'notEquals' then vals.length == 1 ? "#{ref(fm['name'])} != #{vals.first}" : "not In(#{ref(fm['name'])}, #{vals.join(', ')})"
        else raise LightdashWorkbook::Missing, "custom metric #{metric['name']}: filter operator #{filt['operator'].inspect} is not translated"
        end
      prev ? "#{prev} and #{clause}" : clause
    end

    # Trivially translatable table calculation: arithmetic over ${table.field} / ${calc} refs.
    def calc_col(el, name)
      return el.by_key[name] if el.by_key[name]
      c = table_calc(el.chart, name)
      raise LightdashWorkbook::Missing, "table calculation #{name} not found" unless c
      sql = c['sql'].to_s
      if sql.strip.empty?
        kind = c['formula'] ? 'formula-type' : (c['template'] ? 'template' : 'empty')
        raise LightdashWorkbook::Missing, "#{kind} table calculation #{name} has no Sigma translation (#{(c['formula'] || c['template']).inspect})"
      end
      refs = []
      skeleton = sql.gsub(/\$\{([^}]+)\}/) do
        refs << Regexp.last_match(1).strip
        '1'
      end
      unless refs.any? && skeleton =~ %r{\A[\s\d.+\-*/()]*\z}
        raise LightdashWorkbook::Missing, "table calculation #{name} is not simple arithmetic; original SQL: #{sql.strip.gsub(/\s+/, ' ')}"
      end
      formula = sql.gsub(/\$\{([^}]+)\}/) { calc_ref(el, Regexp.last_match(1).strip) }.strip.gsub(/\s+/, ' ')
      display = c['displayName'].to_s.empty? ? name : c['displayName'].to_s
      el.add(name, clean('id' => "#{el.id}-c-calc-#{sanitize(name)}", 'name' => display, 'formula' => formula))
    end

    def calc_ref(el, token)
      fid = token.include?('.') ? token.sub('.', '_') : token
      return "[#{calc_col(el, token).fetch('name')}]" if !token.include?('.') && table_calc(el.chart, token)
      fm = @fm[fid]
      if fm.nil? && custom_metric(el.chart, fid)
        return "(#{custom_metric_col(el, fid)['formula']})"
      end
      raise LightdashWorkbook::Missing, "table calculation references unmapped field #{token}" if fm.nil? || fm['kind'] == 'skipped'
      fm['kind'] == 'metric' ? "[Metrics/#{fm['name']}]" : ref(fm['name'])
    end

    # Any fieldId -> column (metric/dim/custom metric/table calc).
    def col_for(el, fid, inline: false)
      return el.by_key[fid] if el.by_key[fid]
      return custom_metric_col(el, fid) if custom_metric(el.chart, fid)
      return calc_col(el, fid) if table_calc(el.chart, fid)
      fm = @fm[fid]
      raise LightdashWorkbook::Missing, "field #{fid} is not in field-map.json" unless fm
      fm['kind'] == 'metric' ? metric_col(el, fid, inline: inline) : dim_col(el, fid)
    end

    # best effort: record a gap and return nil when a field cannot be built
    def try_col(el, fid, slug, inline: false)
      col_for(el, fid, inline: inline)
    rescue LightdashWorkbook::Missing => e
      gap!('scope-cut', "chart #{slug}: field #{fid}", e.message)
      nil
    end
end
