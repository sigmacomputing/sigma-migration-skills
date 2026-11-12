# frozen_string_literal: true

# Compatibility layer for Power BI partition SQL that the pinned converter
# historically reduced to the first table in the query's FROM clause.
#
# The vendored converter remains immutable/provenance-pinned. This module:
#   1. normalizes array-valued calculation-item expressions before conversion;
#   2. extracts Value.NativeQuery / connector Query= SQL from the original TMSL;
#   3. restores those source elements to Sigma kind:"sql" after conversion.
require 'json'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'

module PbiNativeQuery
  module_function

  Native = Struct.new(:table, :statement, :source, :post_transform, :steps, :database, :refresh_policy, keyword_init: true)
  Step = Struct.new(:name, :fn, :args, keyword_init: true)

  # The result of folding the Power Query steps after a native query:
  # `statement` is the SQL to ship, `renames` maps each Power BI column name to
  # the column the SQL returns, `unsupported` names the steps that could not be
  # folded exactly, and `notes` records the steps accepted as no-ops.
  Fold = Struct.new(:statement, :renames, :folded, :notes, :unsupported, keyword_init: true) do
    def source_name(name)
      renames.fetch(name, name)
    end
  end

  # No-op steps for a model table: Sigma takes column types from the warehouse,
  # never shows a removed column, and neither column order nor row order matters.
  NOOP_STEPS = {
    'Table.TransformColumnTypes' => 'column types come from the warehouse',
    'Table.RemoveColumns' => 'removed columns are not bound',
    'Table.SelectColumns' => 'unselected columns are not bound',
    'Table.ReorderColumns' => 'column order does not matter in a data model',
    'Table.Sort' => 'row order does not matter in a data model',
    'Table.Buffer' => 'buffering has no effect on the result',
    'Table.RemoveRowsWithErrors' => 'no type conversion runs in Sigma, so no conversion errors to remove (approximate)'
  }.freeze

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

  def extract_from_expression(table_name, expression, expressions = nil, refresh_policy = nil)
    text = expression_text(expression)
    if (match = text.match(/\bValue\.NativeQuery\s*\(/i))
      args, end_pos = split_call_args(text, match.end(0))
      decoded = decode_m_string(args[1]) if args.length >= 2
      if decoded && !decoded[0].strip.empty?
        return Native.new(
          table: table_name,
          statement: decoded[0].strip.sub(/;\s*\z/, ''),
          source: 'Value.NativeQuery',
          post_transform: post_transform?(text, end_pos),
          steps: following_steps(text, match.begin(0)),
          database: navigated_database(args[0], expressions, text[0...match.begin(0)]),
          refresh_policy: refresh_policy
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
          post_transform: post_transform?(text, quote_pos + decoded[1]),
          steps: following_steps(text, quote_pos),
          database: nil,
          refresh_policy: refresh_policy
        )
      end
    end
    nil
  end

  def native_queries(model)
    (model['tables'] || []).filter_map do |table|
      partition = (table['partitions'] || []).first
      next unless partition&.dig('source', 'expression')

      extract_from_expression(table['name'], partition.dig('source', 'expression'), model['expressions'],
                              table['refreshPolicy'])
    end
  end

  # Natives whose Power Query steps cannot all be folded: [[native, fold], ...].
  def unfoldable(model, dialect = nil)
    native_queries(model).map { |native| [native, fold(native, dialect)] }
                         .reject { |_native, folded| folded.unsupported.empty? }
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
  def apply!(dm, model, dialect: nil)
    natives = native_queries(model)
    return { 'converted' => [], 'blockers' => [] } if natives.empty?

    tables = convertible_tables(model)
    elements = base_elements(dm)
    all_elements = (dm['pages'] || []).flat_map { |page| page['elements'] || [] }
    converted = []
    blockers = []

    convertible_names = tables.map { |table| table['name'] }
    natives.each do |native|
      # A measure-only table (an "Enter data" table whose only column was removed),
      # a calculation group or a local date template never becomes a converter
      # element, so its native source needs no restoring — not a blocker.
      next unless convertible_names.include?(native.table)

      table_index = tables.index { |table| table['name'] == native.table }
      table = tables[table_index] if table_index
      element = elements[table_index] if table_index
      unless table && element
        blockers << { 'table' => native.table, 'reason' => 'converter element could not be attributed by table order' }
        next
      end

      folded = fold(native, dialect)
      old_name = element['name'].to_s

      source_columns = (table['columns'] || []).reject do |column|
        column['type'] == 'rowNumber' || column['isGenerated'] ||
          column['type'] == 'calculated' || column['dataType'] == 'binary'
      end
      bound = source_columns.zip(element['columns'] || []).map do |column, emitted|
        next unless column && emitted

        output_name = (column['sourceColumn'] || column['name']).to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        [emitted, column, folded.source_name(output_name)]
      end.compact

      # F8: a SQL output column whose name contains "/" cannot be referenced from a Sigma
      # formula ([Custom SQL/a/b] reads as a path), so the statement aliases it and the
      # column binds to the alias. The display name (emitted['name']) is left alone.
      statement, slash_aliases = alias_slash_outputs(folded.statement, bound.map(&:last), dialect)
      element['name'] = native.table
      element['source'] = {
        'connectionId' => element.dig('source', 'connectionId'),
        'kind' => 'sql',
        'statement' => statement
      }
      bound.each do |emitted, column, source|
        emitted['formula'] = "[Custom SQL/#{slash_aliases.fetch(source, source)}]"
        emitted['name'] = column['name'] || (column['sourceColumn'] || column['name']).to_s.sub(/\A\[/, '').sub(/\]\z/, '')
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
        'postTransform' => native.post_transform,
        'database' => native.database,
        'folded' => folded.folded,
        'notes' => folded.notes,
        'unsupported' => folded.unsupported,
        'slashAliases' => slash_aliases
      }
      unless folded.unsupported.empty?
        blockers << {
          'table' => native.table,
          'reason' => 'native SQL is followed by Power Query M transforms that are not represented: ' +
                      folded.unsupported.join(', ')
        }
      end
    end

    { 'converted' => converted, 'blockers' => blockers }
  end

  # ---- "/" in SQL output names (F8) ------------------------------------------

  # Wraps `statement` so every output column named in `names` that contains "/" is
  # returned under an alias with the "/" replaced by "_". Returns [statement, aliases]
  # where aliases maps each original output name to its alias; the statement is returned
  # unchanged (and aliases is empty) when no name contains "/". An alias never collides
  # with another bound output name or with another alias (a numeric suffix breaks ties).
  # Snowflake uses SELECT * RENAME; Databricks and BigQuery have no RENAME, so the column
  # is excluded from * and re-selected under its alias.
  def alias_slash_outputs(statement, names, dialect = nil)
    slashed = names.map(&:to_s).select { |n| n.include?('/') }.uniq
    return [statement, {}] if slashed.empty?

    taken = names.map { |n| n.to_s.downcase }
    aliases = {}
    slashed.each do |name|
      base = name.gsub('/', '_')
      candidate = base
      n = 1
      while taken.include?(candidate.downcase)
        n += 1
        candidate = "#{base}_#{n}"
      end
      taken << candidate.downcase
      aliases[name] = candidate
    end
    q = ->(ident) { quote_ident(ident, dialect) }
    wrapped =
      if %w[bigquery databricks].include?(dialect.to_s.downcase)
        excluded = aliases.keys.map { |k| q.call(k) }.join(', ')
        extras = aliases.map { |k, a| "#{q.call(k)} AS #{q.call(a)}" }.join(', ')
        "SELECT * EXCEPT (#{excluded}), #{extras} FROM (\n#{statement}\n) AS m"
      else
        renames = aliases.map { |k, a| "#{q.call(k)} AS #{q.call(a)}" }.join(', ')
        "SELECT * RENAME (#{renames}) FROM (\n#{statement}\n) AS m"
      end
    [wrapped, aliases]
  end

  # ---- Power Query step folding --------------------------------------------

  # The `let` steps of an M expression, in order, with their character spans.
  def let_steps(text)
    start = let_keyword(text)
    return [] unless start

    steps = []
    i = start + 3
    loop do
      i = skip_m_space(text, i)
      break if i >= text.length || text[i..] =~ /\Ain\b/

      name_match = text[i..].match(/\A(#"(?:[^"]|"")*"|[A-Za-z_][\w.]*)\s*=/)
      return steps unless name_match

      expr_start = i + name_match[0].length
      expr_end = m_expression_end(text, expr_start)
      expr = text[expr_start...expr_end].strip
      call = expr.match(/\A([A-Za-z_][\w.]*)\s*\(/)
      args = call ? split_call_args(expr, call.end(0)).first : []
      steps << { step: Step.new(name: name_match[1], fn: call && call[1], args: args), start: i, end: expr_end }
      i = expr_end
      i += 1 if text[i] == ','
    end
    steps
  end

  # The first `let` keyword outside strings and comments.
  def let_keyword(text)
    i = 0
    while i < text.length
      if text[i] == '"'
        decoded = decode_m_string(text[i..])
        return nil unless decoded

        i += decoded[1]
      elsif text[i, 2] == '//' || text[i, 2] == '/*'
        i = skip_m_space(text, i)
      elsif text[i..] =~ /\Alet\b/ && (i.zero? || text[i - 1] !~ /[\w.#]/)
        return i
      else
        i += 1
      end
    end
    nil
  end

  def skip_m_space(text, i)
    loop do
      i += 1 while i < text.length && text[i] =~ /\s/
      if text[i, 2] == '//'
        i = (text.index("\n", i) || text.length)
      elsif text[i, 2] == '/*'
        i = (text.index('*/', i + 2) || text.length - 2) + 2
      else
        return i
      end
    end
  end

  # End of one step's expression: the next top-level comma or `in`.
  def m_expression_end(text, i)
    depth = 0
    while i < text.length
      ch = text[i]
      if ch == '"'
        i += 1
        i += (text[i] == '"' && text[i + 1] == '"') ? 2 : 1 while i < text.length && !(text[i] == '"' && text[i + 1] != '"')
      elsif text[i, 2] == '//'
        i = (text.index("\n", i) || text.length) - 1
      elsif text[i, 2] == '/*'
        i = (text.index('*/', i + 2) || text.length - 2) + 1
      elsif '([{'.include?(ch)
        depth += 1
      elsif ')]}'.include?(ch)
        depth -= 1
      elsif depth.zero? && (ch == ',' || (text[i..] =~ /\Ain\b/ && text[i - 1] =~ /\s/))
        return i
      end
      i += 1
    end
    text.length
  end

  def following_steps(text, pos)
    steps = let_steps(text)
    idx = steps.index { |s| s[:start] <= pos && pos < s[:end] }
    idx ? steps[(idx + 1)..].map { |s| s[:step] } : []
  end

  # An M literal: string, number, logical, null, or a (nested) list of those.
  # Returns [value, rest] or nil when the text is anything else.
  def m_literal(text)
    t = text.to_s.lstrip
    if t.start_with?('"')
      decoded = decode_m_string(t)
      return decoded && [decoded[0], t[decoded[1]..]]
    end
    if t.start_with?('{')
      items = []
      rest = t[1..].lstrip
      return [items, rest[1..]] if rest.start_with?('}')

      loop do
        parsed = m_literal(rest)
        return nil unless parsed

        items << parsed[0]
        rest = parsed[1].lstrip
        if rest.start_with?(',')
          rest = rest[1..]
        elsif rest.start_with?('}')
          return [items, rest[1..]]
        else
          return nil
        end
      end
    end
    if (num = t.match(/\A-?\d+(?:\.\d+)?/))
      return [num[0].include?('.') ? num[0].to_f : num[0].to_i, t[num[0].length..]]
    end
    { 'true' => true, 'false' => false, 'null' => nil }.each do |word, value|
      return [value, t[word.length..]] if t =~ /\A#{word}\b/
    end
    nil
  end

  def m_value(text)
    parsed = m_literal(text)
    parsed && parsed[1].strip.empty? ? parsed : nil
  end

  def quote_ident(name, dialect)
    if %w[bigquery databricks mysql].include?(dialect.to_s.downcase)
      "`#{name.to_s.gsub('`', '``')}`"
    else
      %("#{name.to_s.gsub('"', '""')}")
    end
  end

  # Folds the steps after the native SQL. Exact folds only: anything else is
  # named in `unsupported` and the orchestrator stops on it.
  def fold(native, dialect = nil)
    renames = {}
    folded = []
    notes = []
    unsupported = []
    wrappers = []
    previous = nil
    # Once columns are dropped, an unkeyed Table.Distinct dedupes only the
    # kept ones, which SELECT DISTINCT * over the full SQL would not.
    narrowed = false
    (native.steps || []).each_with_index do |step, index|
      label = "#{step.name} (#{step.fn || 'expression'})"
      input = step.args.first.to_s.strip
      # Once a step is not folded, the SQL no longer matches the table later
      # steps see (an added column, say), so nothing after it folds either.
      if !unsupported.empty? && NOOP_STEPS.key?(step.fn) && input == previous
        notes << "#{label}: #{NOOP_STEPS[step.fn]}"
        previous = step.name
        next
      end
      if !unsupported.empty? || (index.positive? && input != previous)
        unsupported << label
        previous = step.name
        next
      end
      previous = step.name
      case step.fn
      when 'Table.RenameColumns'
        pairs = m_value(step.args[1].to_s)&.first
        pairs = [pairs] if pairs.is_a?(Array) && pairs.first.is_a?(String)
        if pairs.is_a?(Array) && pairs.all? { |pair| pair.is_a?(Array) && pair.size == 2 && pair.all?(String) }
          mapped = pairs.map { |old, new| [new, renames.fetch(old, old)] }
          pairs.each { |old, _new| renames.delete(old) }
          mapped.each { |new, source| renames[new] = source }
          folded << label
        else
          unsupported << label
        end
      when 'Table.DuplicateColumn'
        from = m_value(step.args[1].to_s)&.first
        to = m_value(step.args[2].to_s)&.first
        if from.is_a?(String) && to.is_a?(String)
          renames[to] = renames.fetch(from, from)
          folded << label
        else
          unsupported << label
        end
      when 'Table.Distinct'
        keys = step.args.size > 1 ? m_value(step.args[1].to_s)&.first : nil
        keys = [keys] if keys.is_a?(String)
        if step.args.size == 1 && !narrowed
          wrappers << [:distinct]
          folded << label
        elsif keys.is_a?(Array) && !keys.empty? && keys.all?(String)
          # Keyed Distinct keeps one whole row per key (Power BI: the first one loaded).
          cols = keys.map { |k| quote_ident(renames.fetch(k, k), dialect) }
          wrappers << [:distinct_on, cols]
          folded << label
          notes << "#{label}: one row per #{keys.join(', ')} via ROW_NUMBER() = 1 (approximation: which row is kept is " \
                   'arbitrary; Power BI keeps the first row it loaded)'
        else
          unsupported << label
        end
      when 'Table.AddIndexColumn'
        name = m_value(step.args[1].to_s)&.first
        start = step.args[2] ? (Integer(step.args[2].to_s.strip, 10) rescue nil) : 0
        inc = step.args[3] ? (Integer(step.args[3].to_s.strip, 10) rescue nil) : 1
        if name.is_a?(String) && start && inc
          over = dialect.to_s.downcase == 'bigquery' ? 'OVER ()' : 'OVER (ORDER BY NULL)'
          wrappers << [:add, quote_ident(name, dialect), "(ROW_NUMBER() #{over} - 1) * #{inc} + #{start}"]
          renames[name] = name
          folded << label
          notes << "#{label}: index assigned by ROW_NUMBER() (approximation: row order is arbitrary, as in Power BI without a prior sort)"
        else
          unsupported << label
        end
      when 'Table.AddColumn'
        name = m_value(step.args[1].to_s)&.first
        expr = name.is_a?(String) ? m_value_sql(step.args[2].to_s, renames, dialect) : nil
        if expr
          wrappers << [:add, quote_ident(name, dialect), expr]
          renames[name] = name
          folded << label
          if step.args[2].to_s =~ /\bText\.From\s*\(/
            # Text.From of a date, datetime, decimal or boolean is CULTURE-formatted text in Power
            # Query ('3/5/2024', '1,5', 'TRUE'); CAST gives ISO dates and the warehouse's own text.
            notes << "#{label}: Text.From folded to CAST(... AS text) (approximation: Power Query formats dates, " \
                     'datetimes, decimals and booleans with the model culture, e.g. 3/5/2024, but the CAST gives ISO ' \
                     'dates and the warehouse number text; exact only for text and whole-number fields, and a ' \
                     'culture argument is not applied)'
          end
        else
          unsupported << label
        end
      when 'Table.SelectRows'
        window = range_window(native.refresh_policy)
        predicate, used_window = m_predicate(step.args[1].to_s, renames, dialect, window)
        if predicate
          wrappers << [:where, predicate]
          folded << label
          if used_window
            notes << "#{label}: RangeStart/RangeEnd folded to a rolling window of #{window[:periods]} #{window[:unit]}(s) " \
                     "from the refresh policy, ending with the current #{window[:end_unit]} and anchored at today's date " \
                     '(approximation: Power BI anchors the window at each refresh, and the pbix cache holds whatever ' \
                     'RangeStart/RangeEnd held when it was saved)'
          end
        else
          unsupported << label
        end
      else
        if NOOP_STEPS.key?(step.fn)
          narrowed = true if %w[Table.RemoveColumns Table.SelectColumns].include?(step.fn)
          notes << "#{label}: #{NOOP_STEPS[step.fn]}"
        else
          unsupported << label
        end
      end
    end
    statement = qualify_tables(native.statement, native.database, dialect)
    wrappers.each do |kind, arg, arg2|
      statement = case kind
                  when :distinct
                    "SELECT DISTINCT * FROM (\n#{statement}\n) AS m"
                  when :distinct_on
                    where = dialect.to_s.downcase == 'bigquery' ? ' WHERE TRUE' : ''
                    "SELECT * FROM (\n#{statement}\n) AS m#{where} QUALIFY ROW_NUMBER() OVER (PARTITION BY #{arg.join(', ')} ORDER BY NULL) = 1"
                  when :add
                    "SELECT m.*, #{arg2} AS #{arg} FROM (\n#{statement}\n) AS m"
                  else
                    "SELECT * FROM (\n#{statement}\n) AS m WHERE #{arg}"
                  end
    end
    Fold.new(statement: statement, renames: renames, folded: folded, notes: notes, unsupported: unsupported)
  end

  # The `each <expr>` of a Table.AddColumn -> a SQL value expression, or nil.
  # Covers what Power BI's UI emits for conditional/custom columns: if/then/else
  # (nested), field refs, literals, #date, M predicates (boolean columns), and
  # Text.Combine({..}) / Text.Proper / Text.Upper / Text.Lower / Text.Trim /
  # Text.From. M null semantics: `if <cond>` with a null comparison takes the
  # else branch, which CASE WHEN does too; Text.Combine skips nulls -> COALESCE ''.
  TEXT_FUNCS = { 'Text.Proper' => 'INITCAP', 'Text.Upper' => 'UPPER', 'Text.Lower' => 'LOWER', 'Text.Trim' => 'TRIM' }.freeze

  def m_value_sql(text, renames, dialect)
    body = text.to_s.strip.sub(/\Aeach\b/, '').strip
    m_value_expr(body, renames, dialect)
  end

  def m_value_expr(src, renames, dialect)
    s = strip_outer_parens(src.to_s.strip)
    return nil if s.empty?

    if s =~ /\Aif\b/
      parts = split_if(s)
      return nil unless parts

      cond, a, b = parts
      cond_sql = m_predicate(cond, renames, dialect, nil).first
      a_sql = m_value_expr(a, renames, dialect)
      b_sql = m_value_expr(b, renames, dialect)
      return nil unless cond_sql && a_sql && b_sql

      return "CASE WHEN #{cond_sql} THEN #{a_sql} ELSE #{b_sql} END"
    end
    if (m = s.match(/\A\[#"((?:[^"]|"")*)"\]\z/) || s.match(/\A\[([^\]]+)\]\z/))
      field = m[1].gsub('""', '"')
      return quote_ident(renames.fetch(field, field), dialect)
    end
    if s.start_with?('"')
      decoded = decode_m_string(s)
      return decoded && decoded[1] == s.length ? "'#{decoded[0].gsub("'", "''")}'" : nil
    end
    return s if s =~ /\A-?\d+(?:\.\d+)?\z/
    return s.upcase if %w[true false null].include?(s)
    if (m = s.match(/\A#date\(\s*(\d{4})\s*,\s*(\d{1,2})\s*,\s*(\d{1,2})\s*\)\z/))
      return "DATE '#{format('%04d-%02d-%02d', m[1].to_i, m[2].to_i, m[3].to_i)}'"
    end
    if (m = s.match(/\A(Text\.[A-Za-z]+)\s*\(/))
      args, finish = split_call_args(s, m.end(0))
      return nil unless finish == s.length

      fn = m[1]
      if TEXT_FUNCS.key?(fn) && args.size == 1
        inner = m_value_expr(args[0], renames, dialect)
        return inner && "#{TEXT_FUNCS[fn]}(#{inner})"
      end
      if fn == 'Text.From' && [1, 2].include?(args.size)
        inner = m_value_expr(args[0], renames, dialect)
        type = %w[bigquery databricks].include?(dialect.to_s.downcase) ? 'STRING' : 'VARCHAR'
        return inner && "CAST(#{inner} AS #{type})"
      end
      if fn == 'Text.Combine' && args.size == 1 && args[0].start_with?('{') && args[0].end_with?('}')
        items, = split_call_args(args[0][1..-2] + ')', 0)
        sqls = items.reject(&:empty?).map { |x| m_value_expr(x, renames, dialect) }
        return nil if sqls.empty? || sqls.any?(&:nil?)

        return '(' + sqls.map { |x| "COALESCE(#{x}, '')" }.join(' || ') + ')'
      end
      return nil
    end
    m_predicate(s, renames, dialect, nil).first
  end

  def strip_outer_parens(s)
    loop do
      break s unless s.start_with?('(') && s.end_with?(')')

      args, finish = split_call_args(s, 1)
      break s unless finish == s.length && args.size == 1

      s = args[0].strip
    end
  end

  # "if C then A else B" -> [C, A, B] at nesting depth 0 (nested if/then/else,
  # parentheses, braces and strings respected), or nil.
  def split_if(s)
    i = 2
    depth = 0
    nest = 0
    marks = {}
    while i < s.length
      ch = s[i]
      if ch == '"'
        j = i + 1
        j += s[j] == '"' && s[j + 1] == '"' ? 2 : 1 while j < s.length && !(s[j] == '"' && s[j + 1] != '"')
        i = j + 1
        next
      end
      if '([{'.include?(ch)
        depth += 1
      elsif ')]}'.include?(ch)
        depth -= 1
      elsif depth.zero? && (i.zero? || s[i - 1] !~ /[\w.]/)
        word = s[i..][/\A(if|then|else)\b/, 1]
        if word == 'if'
          nest += 1
        elsif word == 'then' && nest.zero? && !marks[:then]
          marks[:then] = i
        elsif word == 'else' && nest.zero? && marks[:then] && !marks[:else]
          marks[:else] = i
        elsif word == 'else' && nest.positive?
          nest -= 1
        end
      end
      i += 1
    end
    return nil unless marks[:then] && marks[:else]

    [s[2...marks[:then]].strip, s[(marks[:then] + 4)...marks[:else]].strip, s[(marks[:else] + 4)..].strip]
  end

  # `each <predicate>` over fields and literals -> SQL, or nil when the
  # predicate uses anything this cannot translate with identical semantics.
  # M's `[x] <> v` is true for a null x, so it becomes `(x <> v OR x IS NULL)`.
  def m_predicate_sql(text, renames, dialect)
    m_predicate(text, renames, dialect, nil).first
  end

  # The rolling window an incremental-refresh table's policy describes, or nil
  # when the policy is absent or names a granularity/period count not understood.
  RANGE_UNITS = %w[day month quarter year].freeze

  def range_window(policy)
    return nil unless policy.is_a?(Hash)

    unit = policy['rollingWindowGranularity'].to_s.downcase
    periods = Integer(policy['rollingWindowPeriods'].to_s, 10) rescue nil
    return nil unless RANGE_UNITS.include?(unit) && periods && periods.positive?

    end_unit = policy['incrementalGranularity'].to_s.downcase
    { unit: unit, periods: periods, end_unit: RANGE_UNITS.include?(end_unit) ? end_unit : unit }
  end

  # SQL for RangeStart (:start) or RangeEnd (:end): the start of the rolling
  # window, and the start of the period after the current one.
  def range_bound_sql(kind, window, dialect)
    unit = kind == :start ? window[:unit] : window[:end_unit]
    n = kind == :start ? -window[:periods] : 1
    case dialect.to_s.downcase
    when 'bigquery'
      call = n.negative? ? 'DATE_SUB' : 'DATE_ADD'
      "#{call}(DATE_TRUNC(CURRENT_DATE(), #{unit.upcase}), INTERVAL #{n.abs} #{unit.upcase})"
    when 'databricks'
      "DATEADD(#{unit.upcase}, #{n}, DATE_TRUNC('#{unit.upcase}', CURRENT_DATE()))"
    else
      "DATEADD(#{unit}, #{n}, DATE_TRUNC('#{unit}', CURRENT_DATE()))"
    end
  end

  # Returns [sql, used_window]; sql is nil when the predicate cannot be folded.
  def m_predicate(text, renames, dialect, window)
    used_window = false
    body = text.strip.sub(/\Aeach\b/, '').strip
    tokens = m_predicate_tokens(body)
    return [nil, false] unless tokens

    pos = 0
    peek = -> { tokens[pos] }
    take = -> { tokens[pos].tap { pos += 1 } }
    column = lambda do |field, date_only = false|
      ident = quote_ident(renames.fetch(field, field), dialect)
      date_only && dialect.to_s.downcase == 'bigquery' ? "CAST(#{ident} AS DATE)" : ident
    end
    literal = lambda do |token|
      case token[0]
      when :string then "'#{token[1].gsub("'", "''")}'"
      when :number then token[1]
      when :bool then token[1] ? 'TRUE' : 'FALSE'
      when :date then "DATE '#{token[1]}'"
      end
    end
    compare = nil
    expr = nil
    operand = lambda do
      token = peek.call
      return nil unless token

      if token == [:paren, '(']
        take.call
        inner = expr.call
        return nil unless inner && take.call == [:paren, ')']

        return "(#{inner})"
      end
      compare.call
    end
    compare = lambda do
      left = take.call
      return nil unless left && left[0] == :field

      op = peek.call
      unless op && op[0] == :op
        return "#{column.call(left[1])} = TRUE"
      end

      take.call
      right = take.call
      return nil unless right

      if right[0] == :range
        return nil unless window && %w[>= > < <=].include?(op[1])

        used_window = true
        return "#{column.call(left[1], true)} #{op[1]} #{range_bound_sql(right[1], window, dialect)}"
      end

      col = column.call(left[1])
      if right[0] == :null
        return { '=' => "#{col} IS NULL", '<>' => "#{col} IS NOT NULL" }[op[1]]
      end

      value = literal.call(right)
      return nil unless value

      op[1] == '<>' ? "(#{col} <> #{value} OR #{col} IS NULL)" : "#{col} #{op[1]} #{value}"
    end
    conjunction = lambda do
      left = operand.call
      while left && peek.call == [:word, 'and']
        take.call
        right = operand.call
        left = right && "#{left} AND #{right}"
      end
      left
    end
    expr = lambda do
      left = conjunction.call
      while left && peek.call == [:word, 'or']
        take.call
        right = conjunction.call
        left = right && "#{left} OR #{right}"
      end
      left
    end
    result = expr.call
    result && pos == tokens.size ? [result, used_window] : [nil, false]
  end

  def m_predicate_tokens(text)
    tokens = []
    i = 0
    while i < text.length
      rest = text[i..]
      if rest =~ /\A\s+/
        i += Regexp.last_match(0).length
      elsif (m = rest.match(/\A\[#"((?:[^"]|"")*)"\]/)) || (m = rest.match(/\A\[([^\]]+)\]/))
        tokens << [:field, m[1].gsub('""', '"')]
        i += m[0].length
      elsif rest.start_with?('"')
        decoded = decode_m_string(rest)
        return nil unless decoded

        tokens << [:string, decoded[0]]
        i += decoded[1]
      elsif (m = rest.match(/\A#date\(\s*(\d{4})\s*,\s*(\d{1,2})\s*,\s*(\d{1,2})\s*\)/))
        tokens << [:date, format('%04d-%02d-%02d', m[1].to_i, m[2].to_i, m[3].to_i)]
        i += m[0].length
      elsif (m = rest.match(/\A-?\d+(?:\.\d+)?/))
        tokens << [:number, m[0]]
        i += m[0].length
      elsif (m = rest.match(/\A(<>|<=|>=|=|<|>)/))
        tokens << [:op, m[1]]
        i += m[0].length
      elsif rest =~ /\A[()]/
        tokens << [:paren, rest[0]]
        i += 1
      elsif (m = rest.match(/\A(?:#"(RangeStart|RangeEnd)"|(RangeStart|RangeEnd)\b)/))
        tokens << [:range, (m[1] || m[2]) == 'RangeStart' ? :start : :end]
        i += m[0].length
      elsif (m = rest.match(/\A(and|or|null|true|false)\b/))
        tokens << case m[1]
                  when 'null' then [:null, nil]
                  when 'true', 'false' then [:bool, m[1] == 'true']
                  else [:word, m[1]]
                  end
        i += m[0].length
      else
        return nil
      end
    end
    tokens
  end

  # The database a native query runs in: the {[Name=...]} navigation on its
  # connector, a literal or an M parameter (a model shared expression).
  def navigated_database(connector, expressions, preceding_text = nil)
    expanded = connector.to_s.strip
    steps = let_steps(preceding_text.to_s)
    steps.length.times do
      reference = expanded.match(/\A(#"(?:[^"]|"")*"|[A-Za-z_][\w.]*)/)
      step = reference && steps.reverse.find { |entry| entry[:step].name == reference[1] }
      break unless step

      assignment = preceding_text[step[:start]...step[:end]]
      expanded = assignment.sub(/\A\s*(?:#"(?:[^"]|"")*"|[A-Za-z_][\w.]*)\s*=\s*/, '') +
                 expanded[reference[0].length..]
    end

    nav = expanded.match(/\b(?:Snowflake\.Databases|Databricks\.Catalogs)\s*\(.*?\{\s*\[\s*Name\s*=\s*("(?:[^"]|"")*"|#"(?:[^"]|"")*"|[A-Za-z_][\w.]*)/m)
    return nil unless nav

    ref = nav[1]
    return decode_m_string(ref)&.first if ref.start_with?('"')

    name = ref.start_with?('#"') ? decode_m_string(ref[1..])&.first : ref
    expression = (expressions || []).find { |e| e.is_a?(Hash) && e['name'] == name }
    value = expression && decode_m_string(expression_text(expression['expression']))
    value && !value[0].strip.empty? ? value[0] : nil
  end

  # Prefixes two-part table names that follow FROM or JOIN in a query context
  # with the database. Strings, comments and function arguments such as
  # EXTRACT(YEAR FROM col) are never touched.
  def qualify_tables(sql, database, dialect = nil)
    return sql if database.to_s.empty?

    db = database.match?(/\A[A-Za-z_][A-Za-z0-9_$]*\z/) ? database : quote_ident(database, dialect)
    out = +''
    contexts = [:query]
    from_lists = [false]
    expect_table = false
    i = 0
    while i < sql.length
      rest = sql[i..]
      if rest.start_with?("'")
        j = i + 1
        j += sql[j] == "'" && sql[j + 1] == "'" ? 2 : 1 while j < sql.length && !(sql[j] == "'" && sql[j + 1] != "'")
        out << sql[i..j]
        i = j + 1
      elsif rest.start_with?('--')
        j = sql.index("\n", i) || sql.length
        out << sql[i...j]
        i = j
      elsif rest.start_with?('/*')
        j = (sql.index('*/', i + 2) || sql.length - 2) + 2
        out << sql[i...j]
        i = j
      elsif !expect_table && ['"', '`'].include?(rest[0])
        quote = rest[0]
        j = i + 1
        j += sql[j] == quote && sql[j + 1] == quote ? 2 : 1 while j < sql.length && !(sql[j] == quote && sql[j + 1] != quote)
        out << sql[i..j]
        i = j + 1
      elsif rest.start_with?('(')
        contexts << (sql[(i + 1)..] =~ /\A\s*(SELECT|WITH)\b/i ? :query : :expr)
        from_lists << false
        expect_table = false
        out << '('
        i += 1
      elsif rest.start_with?(')')
        contexts.pop if contexts.size > 1
        from_lists.pop if from_lists.size > 1
        out << ')'
        i += 1
      elsif (m = rest.match(/\A(FROM|JOIN)\b/i)) && (i.zero? || sql[i - 1] !~ /[\w$."`]/)
        expect_table = contexts.last == :query
        from_lists[-1] = true if expect_table
        out << m[0]
        i += m[0].length
      elsif contexts.last == :query && from_lists.last && (i.zero? || sql[i - 1] !~ /[\w$."]/) &&
            (m = rest.match(/\A(WHERE|GROUP|HAVING|QUALIFY|ORDER|LIMIT|OFFSET|FETCH|UNION|EXCEPT|INTERSECT|WINDOW)\b/i))
        from_lists[-1] = false
        expect_table = false
        out << m[0]
        i += m[0].length
      elsif expect_table && rest =~ /\A\s/
        out << sql[i]
        i += 1
      elsif expect_table && (m = rest.match(/\A((?:"(?:[^"]|"")*"|`(?:[^`]|``)*`|[A-Za-z_][\w$]*)(?:\s*\.\s*(?:"(?:[^"]|"")*"|`(?:[^`]|``)*`|[A-Za-z_][\w$]*))*)/))
        parts = m[1].scan(/"(?:[^"]|"")*"|`(?:[^`]|``)*`|[A-Za-z_][\w$]*/)
        out << (parts.size == 2 && sql[i + m[0].length] != '(' ? "#{db}.#{m[1]}" : m[1])
        i += m[0].length
        expect_table = false
      elsif rest.start_with?(',') && contexts.last == :query && from_lists.last
        expect_table = true
        out << ','
        i += 1
      else
        expect_table = false
        out << sql[i]
        i += 1
      end
    end
    out
  end
end
