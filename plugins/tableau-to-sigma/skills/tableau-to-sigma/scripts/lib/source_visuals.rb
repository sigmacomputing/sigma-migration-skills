# frozen_string_literal: true

module SourceVisuals
  module_function

  # Only infer unambiguous display formats from the exported source cells.
  # Explicit Tableau formats are checked by the caller and always win.
  def csv_format(cells, datatype:, locale:)
    values = cells.map { |v| v.to_s.strip }.reject(&:empty?)
    return nil if values.empty? || locale != 'en_US'
    if datatype == 'date' && values.all? { |v| v.match?(%r{\A\d{1,2}/\d{1,2}/\d{4}\z}) }
      return { 'kind' => 'datetime', 'formatString' => '%-m/%-d/%Y' }
    end
    return nil unless %w[integer real].include?(datatype)
    matches = values.map { |v| v.match(/\A(-?)(\$?)(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?(%?)\z/) }
    return nil unless matches.all?
    signatures = matches.map { |m| [m[2], m[4].to_s.length, m[5]] }.uniq
    return nil unless signatures.length == 1
    currency, precision, percent = signatures.first
    return nil if !percent.empty? && datatype != 'real'
    grouping = matches.any? { |m| m[3].include?(',') } ? ',' : ''
    return nil if currency.empty? && percent.empty? && (datatype == 'real' || precision.positive? || grouping.empty?)
    format = { 'kind' => 'number', 'formatString' => "#{currency}#{grouping}.#{precision}#{percent.empty? ? 'f' : '%'}" }
    format['currencySymbol'] = currency unless currency.empty?
    format
  end

  def apply!(element, zone, dashboard, csv_rows, meta, source_formats: {}, mapped_formats: {})
    image_formats = source_formats.each_with_object({}) do |(name, format), formats|
      key = name.to_s.strip.downcase
      raise ArgumentError, "ambiguous source-image display format for #{name}" if formats.key?(key) && formats[key] != format
      formats[key] = format
    end
    fields = (meta['columns_by_guid'] || {}).values.select { |c| c.is_a?(Hash) }
    headers = Array(csv_rows.first)
    rows_shelf = zone['rows_shelf'].is_a?(Hash) ? zone['rows_shelf'] : {}
    cols_shelf = zone['cols_shelf'].is_a?(Hash) ? zone['cols_shelf'] : {}
    # Shelf discreteness is independent of locale, exported cells, and format.
    x_column = element.fetch('columns', []).find { |c| c['id'] && c['id'] == element.dig('xAxis', 'columnId') }
    if x_column
      shelves = Array(rows_shelf['fields']) + Array(cols_shelf['fields'])
      discrete_date = shelves.any? do |field|
        raw = field['raw'].to_s
        token = raw.scan(/\[([^\]]+)\]/).flatten.last.to_s.split(':')[1]
        info = meta.dig('columns_by_guid', field['guid'].to_s) || meta.dig('columns_by_guid', token)
        field['role'] == 'dim' && raw.match?(/:(?:nk|ok)\]\z/) && info &&
          %w[date datetime].include?(info['datatype']) && info['caption'].to_s.strip.casecmp?(x_column['name'].to_s.strip)
      end
      if discrete_date && element.dig('xAxis', 'format', 'visibility') != 'hidden'
        element['xAxis']['format'] ||= {}
        (element['xAxis']['format']['scale'] ||= {})['type'] = 'ordinal'
      end
    end
    element.fetch('columns', []).each do |column|
      name = column['name'].to_s
      next if yield(name)
      # Only a metric picker, not every parameter reference, needs adaptive
      # precision. Preserve a curated format; one image captures only one state.
      if column['formula'].to_s.match?(/\A\s*Switch\s*\(\s*\[ctl-[^\]]+\]\s*,/i)
        column.delete('format') unless mapped_formats.key?(name)
        next
      end
      if image_formats[name.strip.downcase]
        column['format'] = image_formats[name.strip.downcase]
        next
      end
      index = headers.index { |h| h.to_s.strip.casecmp?(name) }
      next unless index
      matches = fields.select { |f| f['caption'].to_s.casecmp?(name) }
      next unless matches.map { |f| f['datatype'] }.uniq.length == 1
      info = matches.first
      format = csv_format(csv_rows.drop(1).map { |r| r[index] },
                          datatype: info['datatype'], locale: dashboard['source_locale'])
      next unless format
      column['format'] = format
    end
    return unless dashboard['source_locale']
    # Undeclared source colors are Tableau defaults, not Sigma theme colors.
    series = Array(element.dig('yAxis', 'columnIds')) + Array(element.dig('yAxis2', 'columnIds'))
    if %w[bar-chart line-chart area-chart].include?(element['kind']) && !element['color'] &&
       series.length == 1 && !zone.dig('channels', 'color') && !zone['mark_color'] && Array(dashboard['brand_palette']).empty?
      element['color'] = { 'by' => 'single', 'value' => '#4e79a7' }
    end
    unstyled = (dashboard['style_rules'] || {}).values.all? { |rules| rules.nil? || rules.empty? }
    if unstyled && Array(zone['axis_formats']).empty? && Array(zone['axis_titles']).empty?
      %w[xAxis yAxis yAxis2].each do |axis|
        next unless element[axis].is_a?(Hash)
        format = (element[axis]['format'] ||= {})
        next if format['visibility'] == 'hidden'
        (format['scale'] ||= {})['hideZeroLine'] = true
        (format['title'] ||= {})['fontSize'] = 12
        (format['labels'] ||= {})['fontSize'] = 12 unless format['labels'] == 'hidden'
      end
    end
    element['style'] ||= {}
    element['style']['backgroundColor'] ||= zone['fill_color'] || 'transparent'
    if !element['style'].key?('borderWidth') && !element['style'].key?('borderColor') &&
       !zone['border_color']
      element['style']['padding'] ||= 'none'
    end
    if unstyled && element['kind'] == 'pivot-table' && Array(element['values']).length == 1 &&
        !rows_shelf['has_measure_names'] && !cols_shelf['has_measure_names']
      element['display'] ||= {}
      element['display']['showLabels'] = 'hidden'
      element['tableStyle'] ||= {
        'preset' => 'presentation', 'gridLines' => 'none', 'outerBorder' => 'hidden',
        'banding' => 'shown', 'bandingColor' => '#f5f5f5',
        'cellSpacing' => 'large',
        'textStyles' => {
          'cell' => { 'fontSize' => 12, 'align' => 'center' },
          'columnHeader' => { 'fontSize' => 12, 'fontWeight' => 'normal', 'backgroundColor' => '#ffffff' },
          'rowHeader' => { 'fontSize' => 12, 'fontWeight' => 'normal', 'backgroundColor' => '#ffffff' }
        }
      }
    end
  end
end
