# frozen_string_literal: true

# DAX calculated tables that are just the distinct values of another table's
# columns, converted to a Custom SQL element.
#
# The pinned converter emits a placeholder SQL element (no name, no columns, no
# relationships) for any calculated table that is not GENERATESERIES / CALENDAR /
# TODAY / a literal list, and the orchestrator's calculated-table gate then stops.
# For the shapes parsed here the warehouse source DOES exist (it is the source
# table's own data), so this module:
#   1. parse(dax)  - recognizes DISTINCT / VALUES / SUMMARIZE / DISTINCT(SELECTCOLUMNS)
#      over one table's plain columns (after comment stripping and unwrapping a
#      single VAR..RETURN and a filter-less CALCULATETABLE); anything else is nil;
#   2. apply!      - rewrites the placeholder into
#      `SELECT DISTINCT <src col> AS "<model col>" FROM (<source SQL>) AS src`,
#      rebuilds the relationships the converter dropped, removes the converter's
#      placeholder warning, and returns an audit record.
# A table the parser does not recognize, or whose source table is unresolved or a
# placeholder, is left exactly as the converter emitted it, so the gate still fires.
require 'json'
require 'digest'
require_relative 'ruby_compat'
require_relative 'pbi_native_query'

module PbiCalcTableSql
  module_function

  # ---- DAX scanning ---------------------------------------------------------

  # Removes // -- and /* */ comments, leaving string literals, 'table names' and
  # [column names] untouched.
  def strip_comments(dax)
    out = +''
    i = 0
    s = dax.to_s
    while i < s.length
      c = s[i]
      two = s[i, 2]
      if c == '"' || c == "'"
        j = i + 1
        while j < s.length
          if s[j] == c
            if s[j + 1] == c then j += 2 else break end
          else
            j += 1
          end
        end
        out << s[i..j].to_s
        i = j + 1
      elsif c == '['
        j = s.index(']', i) || (s.length - 1)
        out << s[i..j]
        i = j + 1
      elsif two == '//' || two == '--'
        i += 1 while i < s.length && s[i] != "\n"
      elsif two == '/*'
        e = s.index('*/', i + 2)
        i = e ? e + 2 : s.length
        out << ' '
      else
        out << c
        i += 1
      end
    end
    out
  end

  # Index of the ")" matching the "(" at open_idx, or nil.
  def matching_paren(s, open_idx)
    depth = 0
    i = open_idx
    while i < s.length
      c = s[i]
      if c == '"' || c == "'"
        j = i + 1
        while j < s.length
          if s[j] == c
            if s[j + 1] == c then j += 2 else break end
          else
            j += 1
          end
        end
        i = j
      elsif c == '['
        i = s.index(']', i) || (s.length - 1)
      elsif c == '('
        depth += 1
      elsif c == ')'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  # Top-level, comma-separated arguments of the text inside a call's parentheses.
  def split_args(inner)
    args = []
    depth = 0
    cur = +''
    i = 0
    while i < inner.length
      c = inner[i]
      if c == '"' || c == "'"
        j = i + 1
        while j < inner.length
          if inner[j] == c
            if inner[j + 1] == c then j += 2 else break end
          else
            j += 1
          end
        end
        cur << inner[i..j].to_s
        i = j + 1
        next
      elsif c == '['
        j = inner.index(']', i) || (inner.length - 1)
        cur << inner[i..j]
        i = j + 1
        next
      elsif c == '('
        depth += 1
      elsif c == ')'
        depth -= 1
      elsif c == ',' && depth.zero?
        args << cur.strip
        cur = +''
        i += 1
        next
      end
      cur << c
      i += 1
    end
    args << cur.strip
    args
  end

  # "NAME(args)" spanning the whole text -> [NAME_upcase, [args]], else nil.
  def call(text)
    m = text.strip.match(/\A([A-Za-z_][A-Za-z0-9_.]*)\s*\(/m)
    return nil unless m

    t = text.strip
    open_idx = m.end(0) - 1
    close = matching_paren(t, open_idx)
    return nil unless close && close == t.length - 1

    [m[1].upcase, split_args(t[(open_idx + 1)...close])]
  end

  # 'Table'[Col] or Table[Col] -> [table, col]; nil for a bare [Measure] or anything else.
  def column_ref(text)
    t = text.strip
    m = t.match(/\A(?:'((?:[^']|'')+)'|([A-Za-z_][A-Za-z0-9_]*))\[([^\]]+)\]\z/)
    return nil unless m

    [(m[1] ? m[1].gsub("''", "'") : m[2]), m[3]]
  end

  def table_ref(text)
    t = text.strip
    m = t.match(/\A(?:'((?:[^']|'')+)'|([A-Za-z_][A-Za-z0-9_]*))\z/)
    m && (m[1] ? m[1].gsub("''", "'") : m[2])
  end

  def string_literal(text)
    m = text.strip.match(/\A"((?:[^"]|"")*)"\z/)
    m && m[1].gsub('""', '"')
  end

  def unwrap(expr)
    e = expr.strip
    10.times do
      var = e.match(/\AVAR\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s+RETURN\s+([A-Za-z_][A-Za-z0-9_]*)\s*\z/mi)
      if var
        return nil unless var[1].casecmp?(var[3])
        return nil if var[2] =~ /\b(?:VAR|RETURN)\b/i

        e = var[2].strip
        next
      end
      c = call(e)
      if c && c[0] == 'CALCULATETABLE'
        return nil unless c[1].size == 1 # any filter argument changes the rows

        e = c[1][0]
        next
      end
      return e
    end
    nil
  end

  # -> { source_table:, columns: [{name:, source_column:}], function: } or nil
  def parse(dax)
    expr = unwrap(strip_comments(dax).strip)
    return nil if expr.nil? || expr.empty?

    c = call(expr)
    return nil unless c

    fn, args = c
    case fn
    when 'DISTINCT', 'VALUES'
      return nil unless args.size == 1

      ref = column_ref(args[0])
      return ref ? shape(ref[0], [{ name: ref[1], source_column: ref[1] }], fn) : parse_selectcolumns(args[0], fn)
    when 'SUMMARIZE'
      return nil if args.size < 2

      tbl = table_ref(args[0])
      return nil unless tbl

      cols = args[1..].map do |a|
        r = column_ref(a)
        return nil unless r && r[0].casecmp?(tbl)

        { name: r[1], source_column: r[1] }
      end
      shape(tbl, cols, fn)
    end
  end

  def parse_selectcolumns(text, outer)
    return nil unless outer == 'DISTINCT'

    c = call(text)
    return nil unless c && c[0] == 'SELECTCOLUMNS' && c[1].size >= 3 && c[1].size.odd?

    tbl = table_ref(c[1][0])
    return nil unless tbl

    cols = c[1][1..].each_slice(2).map do |label, ref|
      name = string_literal(label)
      r = column_ref(ref)
      return nil unless name && r && r[0].casecmp?(tbl)

      { name: name, source_column: r[1] }
    end
    shape(tbl, cols, 'DISTINCT(SELECTCOLUMNS)')
  end

  def shape(table, columns, fn)
    names = columns.map { |x| x[:name].downcase }
    return nil if columns.empty? || names.uniq.size != names.size

    { source_table: table, columns: columns, function: fn }
  end

  # ---- DATATABLE ------------------------------------------------------------

  # DATATABLE("Col", TYPE, ..., {{v, v}, {v, v}}) -> { columns: [names], rows: [[sql literal]] } or nil.
  # Only literal cells (string, number, TRUE/FALSE, BLANK()) are carried; anything else (a function call,
  # a nested expression, a flat one-column list) is nil so the converter's output and the gate stay as they are.
  def parse_datatable(dax, dialect = nil)
    c = call(braces_to_parens(strip_comments(dax).strip))
    return nil unless c && c[0] == 'DATATABLE' && c[1].size >= 3 && c[1].size.odd?

    pairs = c[1][0...-1].each_slice(2).to_a
    names = pairs.map { |label, _type| string_literal(label) }
    return nil if names.any?(&:nil?) || names.map(&:downcase).uniq.size != names.size
    return nil unless pairs.all? { |_label, type| type =~ /\A[A-Za-z0-9_]+\z/ }

    rows = brace_rows(c[1].last)
    return nil if rows.nil? || rows.empty? || rows.any? { |r| r.size != names.size }

    types = pairs.map { |_label, type| type.upcase }
    literals = rows.map { |r| r.each_with_index.map { |cell, i| sql_literal(cell, types[i], dialect) } }
    return nil if literals.flatten.any?(&:nil?)

    { columns: names, rows: literals }
  end

  # "(( a, b ), ( c, d ))" (braces already turned into parentheses) -> [["a", "b"], ["c", "d"]]; nil unless every row is a group.
  def brace_rows(text)
    t = text.to_s.strip
    return nil unless t.start_with?('(') && matching_paren(t, 0) == t.length - 1

    split_args(t[1...-1]).map do |row|
      r = row.strip
      return nil unless r.start_with?('(') && matching_paren(r, 0) == r.length - 1

      split_args(r[1...-1])
    end
  end

  # { } outside string literals and [names] become ( ) so the call/arg scanner can see the row groups.
  def braces_to_parens(text)
    out = +''
    i = 0
    while i < text.length
      c = text[i]
      if c == '"' || c == "'"
        j = i + 1
        while j < text.length
          if text[j] == c
            if text[j + 1] == c then j += 2 else break end
          else
            j += 1
          end
        end
        out << text[i..j].to_s
        i = j + 1
      else
        out << (c == '{' ? '(' : (c == '}' ? ')' : c))
        i += 1
      end
    end
    out
  end

  DT_NUMBER_TYPES = %w[INTEGER INT64 DOUBLE CURRENCY DECIMAL NUMBER].freeze
  NO_BACKSLASH_ESCAPE = %w[postgres postgresql redshift sqlserver mssql].freeze

  # One DATATABLE cell as a typed SQL literal, using the column's declared type. nil when the cell cannot be carried
  # literally for that type (the table is then skipped, never guessed): a string in a number column, a DATE() call, ...
  # BLANK() is NULL for every type. nil dialect = Snowflake. Snowflake, Databricks, BigQuery (and MySQL) treat a
  # backslash in a single-quoted literal as an escape, so it is doubled there; Postgres-family dialects do not.
  def sql_literal(cell, type = nil, dialect = nil)
    t = cell.to_s.strip
    return 'NULL' if t =~ /\ABLANK\(\s*\)\z/i

    str = string_literal(t)
    num = t =~ /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/
    bool = t =~ /\A(?:TRUE|FALSE)\z/i
    type = type.to_s.upcase
    if type == 'STRING' || type == 'TEXT'
      return quote_sql(str, dialect) if str
      return quote_sql(t, dialect) if num || bool

      nil
    elsif DT_NUMBER_TYPES.include?(type)
      num ? t : nil
    elsif type == 'BOOLEAN'
      bool ? t.upcase : nil
    elsif type == 'DATETIME'
      return nil unless str && str =~ /\A\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)?\z/

      "CAST(#{quote_sql(str, dialect)} AS #{%w[bigquery mysql].include?(dialect.to_s.downcase) ? 'DATETIME' : 'TIMESTAMP'})"
    else # VARIANT / unknown: infer from the literal's shape
      return quote_sql(str, dialect) if str
      return t if num
      return t.upcase if bool

      nil
    end
  end

  # Databricks/Spark and BigQuery (and MySQL) do not read '' as an escaped quote ('' is two adjacent literals on Spark,
  # rejected on BigQuery), so their apostrophe is \' with the backslash doubled first. Snowflake and the Postgres
  # family keep ''.
  BACKSLASH_QUOTE_ESCAPE = %w[databricks bigquery mysql].freeze

  def quote_sql(str, dialect)
    d = dialect.to_s.downcase
    s = if BACKSLASH_QUOTE_ESCAPE.include?(d)
          str.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }
        else
          q = str.gsub("'", "''")
          NO_BACKSLASH_ESCAPE.include?(d) ? q : q.gsub('\\') { '\\\\' }
        end
    "'#{s}'"
  end

  # Rewrites the converter's flattened DATATABLE element (one column, the rows run together) into one
  # SELECT per DATATABLE row with every column. Returns the audit record, or a String (the skip reason).
  def convert_datatable!(table, element, dt, taken_ids, new_col_ids, converted_elements, dialect)
    return 'DATATABLE table has calculated columns' if (table['columns'] || []).any? { |c| c['type'] == 'calculated' }
    return 'converter did not emit a placeholder element' unless placeholder?(element)

    model_cols = physical_columns(table)
    pairs = dt[:columns].map { |label| { name: label, source_column: label } }
    model_names = model_cols.empty? ? dt[:columns] : (model_cols.size == dt[:columns].size && pair_by_name(model_cols, pairs))
    return 'DATATABLE columns cannot be paired with the model columns by name' unless model_names

    q = ->(ident) { PbiNativeQuery.quote_ident(ident, dialect) }
    aliases = model_names.map { |n| n.gsub('/', '_') }
    first, *rest = dt[:rows]
    sql = ["SELECT #{first.zip(aliases).map { |v, a| "#{v} AS #{q.call(a)}" }.join(', ')}",
           *rest.map { |r| "SELECT #{r.join(', ')}" }].join(' UNION ALL ')
    name = table['name']
    cols = model_names.each_with_index.map do |n, i|
      id = unique_id("#{name}/#{n}", 22, taken_ids, 'inode-')
      new_col_ids[[name.downcase, n.downcase]] = id
      { 'id' => id, 'formula' => "[Custom SQL/#{aliases[i]}]", 'name' => n }
    end
    element['name'] = name
    element['source'] = { 'connectionId' => element.dig('source', 'connectionId'), 'kind' => 'sql', 'statement' => sql }
    element['columns'] = cols
    element['order'] = cols.map { |c| c['id'] }
    element.delete('ok')
    converted_elements[name.downcase] = element
    { 'table' => name, 'elementId' => element['id'], 'function' => 'DATATABLE', 'source_table' => nil,
      'source_columns' => dt[:columns], 'columns' => model_names, 'sql' => sql,
      'notes' => ["literal DATATABLE rows (#{dt[:rows].size}) as one SELECT per row"], 'pending_calculated_columns' => [] }
  end

  # ---- DM rewrite -----------------------------------------------------------

  PLACEHOLDER = '_placeholder'

  def placeholder?(element)
    element.dig('source', 'statement').to_s.include?(PLACEHOLDER) || element['ok'] == false
  end

  def calculated_partition?(table)
    (table['partitions'] || []).first&.dig('source', 'type') == 'calculated'
  end

  def dax_text(table)
    PbiNativeQuery.expression_text((table['partitions'] || []).first.dig('source', 'expression'))
  end

  # The model columns that become SQL outputs (everything but calculated columns).
  def physical_columns(table)
    (table['columns'] || []).reject do |c|
      c['type'] == 'rowNumber' || c['isGenerated'] || c['type'] == 'calculated' ||
        c['dataType'] == 'binary'
    end
  end

  # Model column names in DAX-output order: each parsed output is matched to the model column whose
  # sourceColumn (the DAX output it binds to, written "[Label]") or, failing that, whose name equals
  # the output label, case-insensitively. Returns nil unless EVERY output pairs with its own column.
  def pair_by_name(model_cols, parsed_columns)
    used = []
    names = parsed_columns.map do |pc|
      label = pc[:name].to_s
      hit = model_cols.find { |c| !used.include?(c) && bare_name(c['sourceColumn']).casecmp?(label) } ||
            model_cols.find { |c| !used.include?(c) && c['name'].to_s.casecmp?(label) }
      return nil unless hit

      used << hit
      hit['name'].to_s
    end
    names
  end

  def bare_name(source_column)
    source_column.to_s.strip.sub(/\A\[(.*)\]\z/m, '\1').sub(/\A'(.*)'\z/m, '\1')
  end

  def short_id(seed, length)
    # Not a security use: a short deterministic id tag that must stay stable across runs.
    # nosemgrep: ruby.lang.security.weak-hashes-sha1.weak-hashes-sha1
    Digest::SHA1.hexdigest(seed).to_i(16).to_s(36).upcase.rjust(length, 'A')[-length..]
  end

  def unique_id(seed, length, taken, prefix = '')
    n = 0
    loop do
      candidate = prefix + short_id("#{seed}##{n}", length)
      unless taken.include?(candidate)
        taken << candidate
        return candidate
      end
      n += 1
    end
  end

  def strip_semicolon(sql)
    sql.to_s.strip.sub(/;\s*\z/, '')
  end

  def tmsl_table(model, name)
    (model['tables'] || []).find { |t| t['name'].to_s.casecmp?(name.to_s) }
  end

  # Mutates dm (converter output) and conv_warnings; returns an audit record.
  def apply!(dm, model, conv_warnings, dialect: nil)
    result = { 'converted' => [], 'skipped' => [] }
    tables = PbiNativeQuery.convertible_tables(model)
    elements = PbiNativeQuery.base_elements(dm)
    all_elements = (dm['pages'] || []).flat_map { |page| page['elements'] || [] }
    taken_ids = []
    all_elements.each do |e|
      taken_ids << e['id']
      (e['columns'] || []).each { |c| taken_ids << c['id'] }
      (e['relationships'] || []).each { |r| taken_ids << r['id'] }
    end
    taken_ids.compact!
    return result if tables.size != elements.size

    # name -> {col name downcase => element column} for every base element
    bind = lambda do |table, element|
      physical_columns(table).zip(element['columns'] || []).each_with_object({}) do |(col, emitted), h|
        h[col['name'].to_s.downcase] = emitted if col && emitted
      end
    end
    new_col_ids = {} # [table downcase, col downcase] => column id for converted tables
    converted_elements = {}

    tables.each_with_index do |table, idx|
      next unless calculated_partition?(table)

      name = table['name']
      skip = lambda do |reason|
        result['skipped'] << { 'table' => name, 'reason' => reason }
        nil
      end
      dt = parse_datatable(dax_text(table), dialect)
      if dt
        done = convert_datatable!(table, elements[idx], dt, taken_ids, new_col_ids, converted_elements, dialect)
        next skip.call(done) if done.is_a?(String)

        result['converted'] << done
        pattern = /\ACalculated table "#{Regexp.escape(name)}"/
        conv_warnings.reject! { |w| w.to_s.sub(/\A[⚠⛔ℹ]\s*/, '') =~ pattern }
        next
      end
      parsed = parse(dax_text(table))
      next skip.call('DAX is not a recognized DISTINCT/VALUES/SUMMARIZE shape') unless parsed

      element = elements[idx]
      next skip.call('converter did not emit a placeholder element') unless placeholder?(element)

      src_idx = tables.index { |t| t['name'].to_s.casecmp?(parsed[:source_table]) }
      src_table = src_idx && tables[src_idx]
      next skip.call("source table '#{parsed[:source_table]}' not found in the model") unless src_table
      next skip.call("source table '#{src_table['name']}' is itself a calculated table") if calculated_partition?(src_table)

      src_el = elements[src_idx]
      src_kind = src_el.dig('source', 'kind')
      next skip.call("source table '#{src_table['name']}' is unresolved (placeholder)") if placeholder?(src_el)

      src_cols = bind.call(src_table, src_el)
      outputs = []
      parsed[:columns].each do |pc|
        src_col = src_cols[pc[:source_column].downcase]
        next outputs << nil unless src_col

        formula = src_col['formula'].to_s
        if src_kind == 'sql'
          m = formula.match(%r{\A\[Custom SQL/(.+)\]\z})
          outputs << (m && { emitted: src_col, output: m[1] })
        elsif src_kind == 'warehouse-table'
          phys = src_col['id'].to_s.split('/', 2)[1]
          outputs << (phys && !phys.empty? && { emitted: src_col, output: phys })
        else
          outputs << nil
        end
      end
      if outputs.any?(&:nil?)
        bad = parsed[:columns].zip(outputs).select { |_, o| o.nil? }.map { |pc, _| pc[:source_column] }
        next skip.call("source column(s) not resolvable on '#{src_table['name']}': #{bad.join(', ')}")
      end

      model_cols = physical_columns(table)
      if model_cols.empty?
        model_names = parsed[:columns].map { |c| c[:name] }
      elsif model_cols.size != parsed[:columns].size
        next skip.call('calculated table column count does not match the DAX shape')
      else
        # TMSL column order is not guaranteed to follow the DAX output order: pair BY NAME
        # (the DAX output label / the column's sourceColumn), never by position.
        model_names = pair_by_name(model_cols, parsed[:columns])
        unless model_names
          next skip.call('calculated table columns cannot be paired with the DAX outputs by name ' \
                         "(model: #{model_cols.map { |c| c['name'] }.join(', ')}; DAX: #{parsed[:columns].map { |c| c[:name] }.join(', ')})")
        end
      end

      q = ->(ident) { PbiNativeQuery.quote_ident(ident, dialect) }
      aliases = model_names.map { |n| n.gsub('/', '_') }
      select = outputs.zip(aliases).map { |o, a| "#{q.call(o[:output])} AS #{q.call(a)}" }.join(', ')
      from =
        if src_kind == 'sql'
          "(\n#{strip_semicolon(src_el.dig('source', 'statement'))}\n) AS src"
        else
          "#{src_el.dig('source', 'path').map { |p| q.call(p) }.join('.')} AS src"
        end
      sql = "SELECT DISTINCT #{select} FROM #{from}"

      cols = model_names.each_with_index.map do |n, i|
        id = unique_id("#{name}/#{n}", 22, taken_ids, 'inode-')
        new_col_ids[[name.downcase, n.downcase]] = id
        { 'id' => id, 'formula' => "[Custom SQL/#{aliases[i]}]", 'name' => n }
      end

      # Calculated columns: the converter drops them for a placeholder. A bare
      # reference to a sibling column is exact; anything else is reported.
      pending = []
      (table['columns'] || []).select { |c| c['type'] == 'calculated' }.each do |cc|
        ref = PbiCalcTableSql.sibling_ref(cc['expression'], name)
        idx2 = ref && model_names.index { |n| n.casecmp?(ref) }
        if idx2
          id = unique_id("#{name}/#{cc['name']}", 22, taken_ids, 'inode-')
          new_col_ids[[name.downcase, cc['name'].to_s.downcase]] = id
          cols << { 'id' => id, 'formula' => "[Custom SQL/#{aliases[idx2]}]", 'name' => cc['name'] }
        else
          pending << { 'name' => cc['name'], 'dax' => PbiNativeQuery.expression_text(cc['expression']) }
        end
      end
      existing = (element['columns'] || []).reject { |c| cols.any? { |n| n['id'] == c['id'] } }
      element['name'] = name
      element['source'] = { 'connectionId' => element.dig('source', 'connectionId'), 'kind' => 'sql', 'statement' => sql }
      element['columns'] = cols + existing
      element['order'] = element['columns'].map { |c| c['id'] }
      element.delete('ok')
      converted_elements[name.downcase] = element

      notes = ['SELECT DISTINCT is case-sensitive; DAX DISTINCT/VALUES collapse text that differs only by case (approximate)']
      if parsed[:function] == 'VALUES'
        notes << 'DAX VALUES may add a blank row for unmatched relationship keys; SELECT DISTINCT does not (approximate)'
      end
      result['converted'] << {
        'table' => name, 'elementId' => element['id'], 'function' => parsed[:function],
        'source_table' => src_table['name'], 'source_columns' => parsed[:columns].map { |c| c[:source_column] },
        'columns' => model_names, 'sql' => sql, 'notes' => notes, 'pending_calculated_columns' => pending
      }
      pattern = /\ACalculated table "#{Regexp.escape(name)}"/
      conv_warnings.reject! { |w| w.to_s.sub(/\A[⚠⛔ℹ]\s*/, '') =~ pattern }
    end

    rebuild_relationships(model, tables, elements, converted_elements, new_col_ids, bind, taken_ids, conv_warnings)
    result
  end

  # Relationships touching a converted table were skipped by the converter
  # ("columns not found"). Re-add the active ones on the from-side element.
  def rebuild_relationships(model, tables, elements, converted, new_col_ids, bind, taken_ids, conv_warnings)
    return if converted.empty?

    column_id = lambda do |tname, cname|
      k = [tname.to_s.downcase, cname.to_s.downcase]
      next new_col_ids[k] if new_col_ids.key?(k)

      idx = tables.index { |t| t['name'].to_s.casecmp?(tname) }
      next nil unless idx
      next nil if calculated_partition?(tables[idx])

      bind.call(tables[idx], elements[idx])[cname.to_s.downcase]&.dig('id')
    end
    (model['relationships'] || []).each do |rel|
      next unless converted.key?(rel['fromTable'].to_s.downcase) || converted.key?(rel['toTable'].to_s.downcase)
      next if rel['isActive'] == false

      f_idx = tables.index { |t| t['name'].to_s.casecmp?(rel['fromTable']) }
      t_idx = tables.index { |t| t['name'].to_s.casecmp?(rel['toTable']) }
      next unless f_idx && t_idx

      from_el = elements[f_idx]
      to_el = elements[t_idx]
      from_col = column_id.call(rel['fromTable'], rel['fromColumn'])
      to_col = column_id.call(rel['toTable'], rel['toColumn'])
      next unless from_col && to_col
      next if (from_el['relationships'] || []).any? { |r| r['targetElementId'] == to_el['id'] }

      (from_el['relationships'] ||= []) << {
        'id' => unique_id("rel/#{rel['fromTable']}/#{rel['toTable']}/#{rel['fromColumn']}", 10, taken_ids),
        'targetElementId' => to_el['id'],
        'keys' => [{ 'sourceColumnId' => from_col, 'targetColumnId' => to_col }],
        'name' => rel['toTable']
      }
      stale = /\ARelationship #{Regexp.escape(rel['fromTable'])}\[#{Regexp.escape(rel['fromColumn'])}\] .{1,3} #{Regexp.escape(rel['toTable'])}\[#{Regexp.escape(rel['toColumn'])}\]: columns not found/
      conv_warnings.reject! { |w| w.to_s.sub(/\A[⚠⛔ℹ]\s*/, '') =~ stale }
    end
  end

  # `[Col]` or `'Table'[Col]` (same table) -> Col, else nil.
  def sibling_ref(expression, table_name)
    text = strip_comments(PbiNativeQuery.expression_text(expression)).strip
    m = text.match(/\A\[([^\]]+)\]\z/)
    return m[1] if m

    r = column_ref(text)
    r && r[0].casecmp?(table_name) ? r[1] : nil
  end
end
