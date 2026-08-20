# frozen_string_literal: true

# Compatibility layer for Power BI partition SQL that the pinned converter
# historically reduced to the first table in the query's FROM clause.
#
# The vendored converter remains immutable/provenance-pinned. This module:
#   1. normalizes array-valued calculation-item expressions before conversion;
#   2. extracts Value.NativeQuery / connector Query= SQL from the original TMSL;
#   3. restores those source elements to Sigma kind:"sql" after conversion.
require 'json'

module PbiNativeQuery
  module_function

  Native = Struct.new(:table, :statement, :source, :post_transform, keyword_init: true)

  def model_from(tmsl)
    tmsl['model'] || tmsl
  end

  def expression_text(value)
    value.is_a?(Array) ? value.join("\n") : value.to_s
  end

  def normalize_tmsl(tmsl)
    copy = JSON.parse(JSON.generate(tmsl))
    (model_from(copy)['tables'] || []).each do |table|
      items = table.dig('calculationGroup', 'calculationItems') || []
      items.each do |item|
        item['expression'] = expression_text(item['expression']) if item['expression'].is_a?(Array)
      end
    end
    copy
  end

  def split_call_args(text, start_idx)
    args = []
    depth = 1
    arg_start = start_idx
    quote = nil
    i = start_idx
    while i < text.length
      ch = text[i]
      if quote
        if ch == quote
          if quote == '"' && text[i + 1] == '"'
            i += 2
            next
          end
          quote = nil
        end
        i += 1
        next
      end
      if ch == '"' || ch == "'"
        quote = ch
      elsif '([{'.include?(ch)
        depth += 1
      elsif ')]}'.include?(ch)
        depth -= 1
        if depth.zero?
          args << text[arg_start...i].strip
          return [args, i + 1]
        end
      elsif ch == ',' && depth == 1
        args << text[arg_start...i].strip
        arg_start = i + 1
      end
      i += 1
    end
    [args, i]
  end

  def decode_m_string(raw)
    text = raw.to_s.strip
    return nil unless text.start_with?('"')

    out = +''
    i = 1
    while i < text.length
      if text[i] == '"'
        if text[i + 1] == '"'
          out << '"'
          i += 2
          next
        end
        return [out, i + 1]
      end
      if text[i, 2] == '#('
        close = text.index(')', i + 2)
        if close
          decoded = text[(i + 2)...close].split(',').map do |token|
            case token.strip.downcase
            when 'lf' then "\n"
            when 'cr' then "\r"
            when 'tab' then "\t"
            else
              t = token.strip
              t.match?(/\A[0-9a-f]{4,8}\z/i) ? [t.to_i(16)].pack('U') : "#(#{token})"
            end
          end.join
          out << decoded
          i = close + 1
          next
        end
      end
      out << text[i]
      i += 1
    end
    nil
  end

  def post_transform?(text, end_pos)
    tail = text[end_pos..].to_s
    before_in = tail.split(/\n\s*in\s+/i, 2).first.to_s
    before_in.match?(/(?:^|[\r\n])\s*(?:#"(?:[^"]|"")*"|[A-Za-z_][\w.]*)\s*=/m)
  end

  def extract_from_expression(table_name, expression)
    text = expression_text(expression)
    if (match = text.match(/\bValue\.NativeQuery\s*\(/i))
      args, end_pos = split_call_args(text, match.end(0))
      decoded = decode_m_string(args[1]) if args.length >= 2
      if decoded && !decoded[0].strip.empty?
        return Native.new(
          table: table_name,
          statement: decoded[0].strip.sub(/;\s*\z/, ''),
          source: 'Value.NativeQuery',
          post_transform: post_transform?(text, end_pos)
        )
      end
    end

    if (match = text.match(/\bQuery\s*=\s*"/i))
      quote_pos = text.index('"', match.begin(0))
      decoded = decode_m_string(text[quote_pos..]) if quote_pos
      if decoded && !decoded[0].strip.empty?
        return Native.new(
          table: table_name,
          statement: decoded[0].strip.sub(/;\s*\z/, ''),
          source: 'Query option',
          post_transform: post_transform?(text, quote_pos + decoded[1])
        )
      end
    end
    nil
  end

  def native_queries(model)
    (model['tables'] || []).filter_map do |table|
      partition = (table['partitions'] || []).first
      next unless partition&.dig('source', 'expression')

      extract_from_expression(table['name'], partition.dig('source', 'expression'))
    end
  end

  def convertible_tables(model)
    (model['tables'] || []).reject do |table|
      name = table['name'].to_s
      calc_group = table['calculationGroup']
      cols = (table['columns'] || []).reject { |c| c['type'] == 'rowNumber' || c['isGenerated'] }
      measures_only = cols.empty? && (table['measures'] || []).any?
      calc_group || measures_only ||
        name.start_with?('LocalDateTable_', 'DateTableTemplate_')
    end
  end

  def base_elements(dm)
    (dm['pages'] || []).flat_map { |page| page['elements'] || [] }.select do |element|
      %w[warehouse-table sql].include?(element.dig('source', 'kind')) &&
        element.dig('source', 'connectionId')
    end
  end

  # Mutates dm (the converter output) and returns a result artifact.
  def apply!(dm, model)
    natives = native_queries(model)
    return { 'converted' => [], 'blockers' => [] } if natives.empty?

    tables = convertible_tables(model)
    elements = base_elements(dm)
    all_elements = (dm['pages'] || []).flat_map { |page| page['elements'] || [] }
    converted = []
    blockers = []

    natives.each do |native|
      table_index = tables.index { |table| table['name'] == native.table }
      table = tables[table_index] if table_index
      element = elements[table_index] if table_index
      unless table && element
        blockers << { 'table' => native.table, 'reason' => 'converter element could not be attributed by table order' }
        next
      end

      old_name = element['name'].to_s
      element['name'] = native.table
      element['source'] = {
        'connectionId' => element.dig('source', 'connectionId'),
        'kind' => 'sql',
        'statement' => native.statement
      }

      source_columns = (table['columns'] || []).reject do |column|
        column['type'] == 'rowNumber' || column['isGenerated'] ||
          column['type'] == 'calculated' || column['dataType'] == 'binary'
      end
      source_columns.zip(element['columns'] || []).each do |column, emitted|
        next unless column && emitted

        output_name = (column['sourceColumn'] || column['name']).to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        emitted['formula'] = "[Custom SQL/#{output_name}]"
        emitted['name'] = column['name'] || output_name
      end

      # The pinned converter built relationship Views while this was still a
      # warehouse-table. Keep them, but point their formulas/names at the newly
      # restored logical base name.
      all_elements.each do |child|
        next unless child.dig('source', 'kind') == 'table' &&
                    child.dig('source', 'elementId') == element['id']

        child['name'] = "#{native.table} View" if child['name'].to_s == "#{old_name} View"
        (child['columns'] || []).each do |column|
          formula = column['formula']
          column['formula'] = formula.sub("[#{old_name}/", "[#{native.table}/") if formula.is_a?(String)
        end
      end

      converted << {
        'table' => native.table,
        'elementId' => element['id'],
        'source' => native.source,
        'postTransform' => native.post_transform
      }
      if native.post_transform
        blockers << {
          'table' => native.table,
          'reason' => 'native SQL is followed by Power Query M transforms that are not represented'
        }
      end
    end

    { 'converted' => converted, 'blockers' => blockers }
  end
end
