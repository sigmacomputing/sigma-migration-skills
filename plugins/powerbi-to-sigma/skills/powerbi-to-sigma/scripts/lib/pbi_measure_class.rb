# frozen_string_literal: true
# pbi_measure_class.rb — classify every Power BI measure on a visible visual for the Power BI-shaped
# model mode (`migrate-powerbi.rb --model-shape pbi`). Later tasks build each class differently, so a
# wrong class means wrong numbers or a lost measure; every doubtful case therefore falls to D.
#
#   A  plain: aggregates / arithmetic / DIVIDE over ONE table's own columns, literal filters on them
#   B  needs a related column (RELATED, a filter on a dimension column) or a USERELATIONSHIP
#   C  time intelligence (YTD/QTD/MTD, prior year/period, rolling N days) over an A or B measure
#   D  everything else: snapshot logic, per-entity bucketing, cross-fact, anything unparseable
#
# Classification runs over the TMSL model and its relationships (Power BI semantics, inactive ones
# included). Path hops are named with PbiShapedModel.relationship_name (the Sigma relationship names).
# Measure names are unique per model in Power BI, so classes are keyed "<table>.<measure>".
require 'set'
require 'json'
require_relative 'pbi_shaped_model'

module PbiMeasureClass
  module_function

  AGGREGATES = %w[SUM AVERAGE MIN MAX COUNT COUNTA COUNTROWS DISTINCTCOUNT SUMX AVERAGEX MINX MAXX COUNTX].freeze
  SCALARS = %w[DIVIDE IF SWITCH ISBLANK BLANK TRUE FALSE ABS ROUND INT COALESCE AND OR NOT DATE YEAR MONTH DAY
               EOMONTH].freeze
  TI_TOTALS = { 'TOTALYTD' => 'ytd', 'TOTALQTD' => 'qtd', 'TOTALMTD' => 'mtd' }.freeze
  TI_FILTERS = (%w[DATESYTD DATESQTD DATESMTD SAMEPERIODLASTYEAR DATEADD PARALLELPERIOD PREVIOUSYEAR
                   PREVIOUSQUARTER PREVIOUSMONTH DATESINPERIOD DATESBETWEEN]).freeze
  REMOVE_FILTERS = %w[ALL ALLEXCEPT ALLSELECTED ALLNOBLANKROW REMOVEFILTERS].freeze
  ITERATE_ENTITIES = %w[VALUES DISTINCT SUMMARIZE SUMMARIZECOLUMNS ADDCOLUMNS FILTER TOPN RANKX CROSSJOIN
                        GENERATE SELECTCOLUMNS TREATAS CALCULATETABLE].freeze
  INLINE_TABLES = %w[DATATABLE GENERATESERIES ROW].freeze

  # --- tokenizer + tree ----------------------------------------------------------------------

  def tokenize(src)
    toks = []
    i = 0
    n = src.length
    while i < n
      c = src[i]
      if c =~ /\s/
        i += 1
      elsif src[i, 2] == '//' || src[i, 2] == '--'
        i += 1 while i < n && src[i] != "\n"
      elsif src[i, 2] == '/*'
        e = src.index('*/', i + 2)
        i = e ? e + 2 : n
      elsif c == '"'
        j = i + 1
        while j < n
          if src[j] == '"' && src[j + 1] == '"' then j += 2
          elsif src[j] == '"' then break
          else j += 1
          end
        end
        toks << [:str, src[i..j]]
        i = j + 1
      elsif c == "'"
        j = i + 1
        while j < n
          if src[j] == "'" && src[j + 1] == "'" then j += 2
          elsif src[j] == "'" then break
          else j += 1
          end
        end
        toks << [:quoted, src[(i + 1)...j].gsub("''", "'")]
        i = j + 1
      elsif c == '['
        j = i + 1
        while j < n
          if src[j] == ']' && src[j + 1] == ']' then j += 2
          elsif src[j] == ']' then break
          else j += 1
          end
        end
        toks << [:bracket, src[(i + 1)...j].gsub(']]', ']')]
        i = j + 1
      elsif c =~ /[0-9]/
        m = src[i..-1].match(/\A[0-9]+(?:\.[0-9]+)?/)
        toks << [:num, m[0]]
        i += m[0].length
      elsif c =~ /[A-Za-z_]/
        m = src[i..-1].match(/\A[A-Za-z_][A-Za-z0-9_.]*/)
        toks << [:ident, m[0]]
        i += m[0].length
      else
        toks << [:op, c]
        i += 1
      end
    end
    toks
  end

  # Nodes: [:call, FN, [argNodes...]] [:col, table, col] [:bare, name] [:tbl, name] [:id, name]
  #        [:var, name, bodyNodes] [:lit, text]
  class Parser
    def initialize(toks, tables)
      @t = toks
      @p = 0
      @tables = tables
    end

    def parse
      seq(false)
    end

    def peek(k = 0)
      @t[@p + k]
    end

    def seq(in_var)
      out = []
      while @p < @t.length
        tok = peek
        break if tok[0] == :op && (tok[1] == ')' || tok[1] == ',')
        if tok[0] == :ident && %w[VAR RETURN].include?(tok[1].upcase)
          break if in_var
          if tok[1].upcase == 'VAR'
            @p += 1
            name = peek && peek[1]
            @p += 1
            @p += 1 if peek && peek == [:op, '=']
            out << [:var, name, seq(true)]
          else
            @p += 1
          end
          next
        end
        out << atom
      end
      out
    end

    def atom
      tok = @t[@p]
      @p += 1
      case tok[0]
      when :str, :num then [:lit, tok[1]]
      when :op
        if tok[1] == '('
          inner = args_until_close
          [:call, '', inner]
        else
          [:lit, tok[1]]
        end
      when :bracket then [:bare, tok[1]]
      when :ident, :quoted
        nxt = peek
        if tok[0] == :ident && nxt == [:op, '(']
          @p += 1
          [:call, tok[1].upcase, args_until_close]
        elsif nxt && nxt[0] == :bracket
          @p += 1
          [:col, tok[1], nxt[1]]
        elsif tok[0] == :quoted || @tables.include?(tok[1])
          [:tbl, tok[1]]
        else
          [:id, tok[1]]
        end
      end
    end

    def args_until_close
      args = []
      loop do
        args << seq(false)
        tok = peek
        if tok.nil?
          break
        elsif tok == [:op, ',']
          @p += 1
        else
          @p += 1 # ')'
          break
        end
      end
      args = [] if args == [[]]
      args
    end
  end

  # --- model helpers -------------------------------------------------------------------------

  def model_of(tmsl)
    tmsl['model'] || tmsl
  end

  def expr_text(m)
    e = m['expression']
    e.is_a?(Array) ? e.join("\n") : e.to_s
  end

  def key_of(table, measure)
    "#{table}.#{measure}"
  end

  # queryRef ("Sales.Sales Amount" or a bare "Sales Amount") -> [table, measure] or nil
  def resolve_measure_ref(ref, tmsl)
    tables = Array(model_of(tmsl)['tables'])
    ref = ref.to_s
    tables.each do |t|
      next unless ref.start_with?("#{t['name']}.")
      rest = ref[(t['name'].length + 1)..-1]
      return [t['name'], rest] if Array(t['measures']).any? { |m| m['name'] == rest }
    end
    hits = []
    tables.each { |t| Array(t['measures']).each { |m| hits << [t['name'], m['name']] if m['name'] == ref } }
    hits.length == 1 ? hits[0] : nil
  end

  def visible_measures(signals, tmsl)
    seen = Set.new
    out = []
    Array(signals['pages']).each do |page|
      next if page['hidden']
      Array(page['visuals']).each do |v|
        next if v['hidden']
        (v['bindings'] || {}).each_value do |refs|
          Array(refs).each do |ref|
            hit = resolve_measure_ref(ref, tmsl)
            next unless hit && seen.add?(hit)
            out << { 'table' => hit[0], 'measure' => hit[1] }
          end
        end
      end
    end
    out
  end

  # --- analysis context (one per classification run, memoised) ------------------------------

  class Ctx
    attr_reader :tmsl, :rels, :tables, :measures

    def initialize(tmsl, relationships)
      @tmsl = tmsl
      @rels = Array(relationships)
      model = PbiMeasureClass.model_of(tmsl)
      @tables = {}
      @measures = {}
      Array(model['tables']).each do |t|
        @tables[t['name']] = Array(t['columns']).map { |c| c['name'] }
        Array(t['measures']).each { |m| @measures[m['name']] = [t['name'], m] }
      end
      @memo = {}
      @active = Set.new
      @edges = Hash.new { |h, k| h[k] = [] }
      @rels.each do |r|
        next if r['isActive'] == false
        @edges[r['fromTable']] << r
      end
    end

    # shortest many-to-one path of active relationships; array of relationship names, [] when same
    # table, nil when unreachable
    def path(from, to)
      return [] if from == to
      seen = Set.new([from])
      queue = [[from, []]]
      until queue.empty?
        cur, names = queue.shift
        @edges[cur].each do |r|
          nxt = r['toTable']
          next unless seen.add?(nxt)
          nn = names + [PbiShapedModel.relationship_name(r)]
          return nn if nxt == to
          queue << [nxt, nn]
        end
      end
      nil
    end

    # every table reachable from `from` by active many-to-one hops (itself included)
    def reach(from)
      seen = Set.new([from])
      queue = [from]
      until queue.empty?
        @edges[queue.shift].each { |r| queue << r['toTable'] if seen.add?(r['toTable']) }
      end
      seen.to_a
    end

    def linked?(a, b)
      !path(a, b).nil? || !path(b, a).nil?
    end

    def classify(table, name)
      key = PbiMeasureClass.key_of(table, name)
      return @memo[key] if @memo.key?(key)
      if @active.include?(key)
        return PbiMeasureClass.result('D', 'measure references itself (circular)')
      end
      @active << key
      res = begin
        PbiMeasureClass.compute(self, table, name)
      rescue StandardError => e
        PbiMeasureClass.result('D', "could not be parsed (#{e.class}: #{e.message})")
      end
      @active.delete(key)
      @memo[key] = res
    end
  end

  def result(klass, reason, extra = {})
    { 'class' => klass, 'reason' => reason, 'related' => [], 'userel' => nil, 'ti' => nil, 'home' => nil }.merge(extra)
  end

  # --- single-measure walk -------------------------------------------------------------------

  class Collector
    attr_accessor :direct_tables, :direct_cols, :related, :filters, :ti_refs, :measures, :measure_in_filter

    def initialize
      @direct_tables = Set.new
      @direct_cols = []
      @related = []
      @filters = []
      @ti_refs = []
      @measures = []
    end
  end

  class Walk
    attr_reader :d, :userel, :tis, :vars, :var_collectors
    attr_accessor :col

    def initialize(ctx, table)
      @ctx = ctx
      @table = table
      @col = Collector.new
      @d = nil
      @userel = []
      @tis = []
      @vars = {}
      @var_collectors = []
    end

    def fail!(reason)
      @d ||= reason
    end

    def nodes(list, cx)
      list.each { |n| node(n, cx) }
    end

    def node(n, cx)
      case n[0]
      when :call then call(n, cx)
      when :col then column(n[1], n[2], cx)
      when :bare then bare(n[1], cx)
      when :tbl
        if cx[:ti] then nil
        elsif cx[:filter] then fail!("filters on the whole table #{n[1]}")
        else @col.direct_tables << n[1]
        end
      when :var
        @vars[n[1]] = n[2]
        saved = @col
        @col = Collector.new
        nodes(n[2], cx)
        @var_collectors << @col
        @col = saved
      end
    end

    def column(t, c, cx)
      unless @ctx.tables.key?(t) && @ctx.tables[t].include?(c)
        # DAX allows a table-qualified measure reference: Sales[Units] is the measure when Sales has no
        # such column, even if another table has a column of that name
        mt, = @ctx.measures[c]
        return bare(c, cx) if mt == t
        return fail!("references #{t}[#{c}], which is not a column in the model")
      end
      if cx[:ti] then @col.ti_refs << [t, c]
      elsif cx[:related] then @col.related << [t, c]
      elsif cx[:filter] then @col.filters << [t, c]
      else
        @col.direct_tables << t
        @col.direct_cols << [t, c]
      end
    end

    def bare(name, cx)
      if @ctx.measures.key?(name)
        return fail!("filters on the value of measure [#{name}]") if cx[:filter]
        @col.measures << name unless cx[:ti]
      elsif @ctx.tables[@table].to_a.include?(name)
        column(@table, name, cx)
      else
        fail!("references [#{name}], which is neither a measure nor a column of #{@table}")
      end
    end

    def call(n, cx)
      fn = n[1]
      args = n[2]
      if fn == '' || AGGREGATES.include?(fn) || SCALARS.include?(fn)
        args.each { |a| nodes(a, cx) }
      elsif fn == 'RELATED'
        args.each { |a| nodes(a, cx.merge(related: true)) }
      elsif fn == 'CALCULATE'
        calculate(args, cx)
      elsif fn == 'USERELATIONSHIP'
        userelationship(args, cx)
      elsif TI_TOTALS.key?(fn)
        record_ti(fn, args, args[0], 0, cx)
        nodes(args[0], cx) if args[0]
        args[1..-1].to_a.each { |a| nodes(a, cx.merge(ti: true)) }
      elsif TI_FILTERS.include?(fn)
        fail!("uses #{fn} outside a CALCULATE filter")
      elsif REMOVE_FILTERS.include?(fn)
        fail!("uses #{fn}, which removes filters (snapshot or share-of-total logic)")
      elsif ITERATE_ENTITIES.include?(fn)
        fail!("uses #{fn}, which iterates over entities (per-entity bucketing)")
      elsif INLINE_TABLES.include?(fn)
        fail!("uses #{fn}, which builds a table inline")
      else
        fail!("uses #{fn}, which this mode does not translate")
      end
    end

    def calculate(args, cx)
      base = args[0] || []
      nodes(base, cx)
      extra = 0
      args[1..-1].to_a.each do |a|
        if a.length == 1 && a[0][0] == :call && TI_FILTERS.include?(a[0][1])
          record_ti(a[0][1], a[0][2], base, nil, cx)
          a[0][2].each { |x| nodes(x, cx.merge(ti: true)) }
        else
          extra += 1
          nodes(a, cx.merge(filter: true))
        end
      end
      @tis.each { |t| t[:extra_filters] = extra if t[:extra_filters].nil? }
    end

    def record_ti(fn, args, base, extra, cx)
      @tis << { fn: fn, args: args, base: base, extra_filters: extra, in_filter: cx[:filter] }
    end

    def userelationship(args, cx)
      cols = args.map { |a| a.length == 1 && a[0][0] == :col ? [a[0][1], a[0][2]] : nil }
      return fail!('USERELATIONSHIP arguments are not plain columns') if cols.length != 2 || cols.any?(&:nil?)
      rel = @ctx.rels.find do |r|
        (r['fromTable'] == cols[0][0] && r['fromColumn'] == cols[0][1] && r['toTable'] == cols[1][0] && r['toColumn'] == cols[1][1]) ||
          (r['fromTable'] == cols[1][0] && r['fromColumn'] == cols[1][1] && r['toTable'] == cols[0][0] && r['toColumn'] == cols[0][1])
      end
      return fail!("USERELATIONSHIP names no relationship in the model (#{cols.map { |c| "#{c[0]}[#{c[1]}]" }.join(', ')})") unless rel
      @userel << rel if rel['isActive'] == false
    end
  end

  # --- ti pattern recognition ----------------------------------------------------------------

  def lit_text(nodes)
    nodes.map do |n|
      case n[0]
      when :lit, :id, :bare, :tbl then n[1]
      when :col then "#{n[1]}[#{n[2]}]"
      when :call then "#{n[1]}(#{n[2].map { |a| lit_text(a) }.join(', ')})"
      else ''
      end
    end.join(' ')
  end

  # -> [pattern, days_or_nil, unit_or_nil] or [nil, reason, nil]
  def ti_pattern(t)
    fn = t[:fn]
    args = t[:args]
    max_args = TI_TOTALS.key?(fn) ? 2 : 1
    if (TI_TOTALS.key?(fn) || %w[DATESYTD DATESQTD DATESMTD].include?(fn)) && args.length > max_args
      return [nil, "#{fn} has an extra argument (#{lit_text(args[max_args])}): a year-end or a filter changes the window", nil]
    end
    return [TI_TOTALS[fn], nil, nil] if TI_TOTALS.key?(fn)
    case fn
    when 'DATESYTD' then ['ytd', nil, nil]
    when 'DATESQTD' then ['qtd', nil, nil]
    when 'DATESMTD' then ['mtd', nil, nil]
    when 'SAMEPERIODLASTYEAR', 'PREVIOUSYEAR' then ['py', nil, nil]
    when 'PREVIOUSQUARTER' then ['pp', nil, 'quarter']
    when 'PREVIOUSMONTH' then ['pp', nil, 'month']
    when 'DATEADD', 'PARALLELPERIOD'
      n = lit_text(args[1] || []).delete(' ')
      unit = lit_text(args[2] || []).strip.upcase
      return [nil, "#{fn} with #{args.length} arguments is not a recognised prior-period shift", nil] if args.length != 3
      return ['py', nil, nil] if n == '-1' && unit == 'YEAR'
      return ['pp', nil, unit.downcase] if n == '-1' && %w[QUARTER MONTH].include?(unit)
      [nil, "#{fn} shift #{n} #{unit} is not exactly one year, quarter or month back", nil]
    when 'DATESINPERIOD'
      n = lit_text(args[2] || []).delete(' ')
      unit = lit_text(args[3] || []).strip.upcase
      return [nil, 'DATESINPERIOD counts in units other than DAY', nil] unless unit == 'DAY' && n =~ /\A-\d+\z/
      dates = lit_text(args[0] || [])
      end_ok = lit_text(args[1] || []).delete(' ') == "MAX(#{dates})".delete(' ')
      return [nil, 'DATESINPERIOD must run backwards from MAX of its date column', nil] unless end_ok
      ['rolling', n.to_i.abs, nil]
    when 'DATESBETWEEN'
      s = lit_text(args[1] || [])
      e = lit_text(args[2] || [])
      if s =~ /DATE\s*\(\s*YEAR\s*\([^)]*\)\s*,\s*1\s*,\s*1\s*\)/i then ['ytd', nil, nil]
      elsif s =~ /DATE\s*\(\s*YEAR\s*\([^)]*\)\s*,\s*MONTH\s*\([^)]*\)\s*,\s*1\s*\)/i then ['mtd', nil, nil]
      elsif (m = datesbetween_rolling(lit_text(args[0] || []), s, e)) then ['rolling', m, nil]
      else [nil, 'DATESBETWEEN window is not a recognised YTD, MTD or day offset', nil]
      end
    else
      [nil, "#{fn} is not a recognised time-intelligence function", nil]
    end
  end

  # I5: DATESBETWEEN as a rolling window mirrors DATESINPERIOD: the end is MAX(<date col>) and the start is
  # MAX(<date col>) - N, over the same column. A bare-measure anchor, MIN(...) - N or any other end is not a rolling
  # window ending at the context's last day, so it stays unrecognised (class D). Returns the day count (N + 1) or nil.
  def datesbetween_rolling(dates, start_text, end_text)
    d = Regexp.escape(dates.delete(' '))
    return nil if dates.strip.empty?
    return nil unless end_text.delete(' ') =~ /\AMAX\(#{d}\)\z/
    m = start_text.delete(' ').match(/\AMAX\(#{d}\)-(\d+)\z/)
    m && m[1].to_i + 1
  end

  def first_col(nodes)
    nodes.each do |n|
      return [n[1], n[2]] if n[0] == :col
      next unless n[0] == :call
      n[2].each do |a|
        r = first_col(a)
        return r if r
      end
    end
    nil
  end

  # --- the classification ---------------------------------------------------------------------

  def compute(ctx, table, name)
    tab, m = ctx.measures[name]
    return result('D', 'measure not found in the model') unless m && tab == table
    toks = tokenize(expr_text(m))
    tree = Parser.new(toks, ctx.tables.keys).parse
    w = Walk.new(ctx, table)
    w.nodes(tree, {})
    return result('D', w.d) if w.d

    # VAR bodies are anchors when a time-intelligence function is present, ordinary refs otherwise
    var_refs = w.var_collectors
    unless w.tis.empty?
      var_refs.each { |vc| w.col.ti_refs.concat(vc.direct_cols).concat(vc.ti_refs) }
      var_refs.each do |vc|
        w.col.measures.concat(vc.measures)
        w.col.related.concat(vc.related)
        w.col.filters.concat(vc.filters)
      end
    else
      var_refs.each do |vc|
        w.col.direct_tables.merge(vc.direct_tables)
        w.col.direct_cols.concat(vc.direct_cols)
        w.col.related.concat(vc.related)
        w.col.filters.concat(vc.filters)
        w.col.measures.concat(vc.measures)
        w.col.ti_refs.concat(vc.ti_refs)
      end
    end

    # sub-measures
    subs = w.col.measures.uniq.map do |sn|
      st, = ctx.measures[sn]
      [sn, ctx.classify(st, sn)]
    end
    subs.each do |sn, sr|
      return result('D', "depends on class D measure [#{sn}]: #{sr['reason']}") if sr['class'] == 'D'
    end

    # time intelligence
    own_ti = w.tis
    return result('D', 'uses more than one time-intelligence function') if own_ti.length > 1
    ti = nil
    if own_ti.length == 1
      t = own_ti[0]
      pattern, extra, unit = ti_pattern(t)
      return result('D', extra) unless pattern
      return result('D', "#{t[:fn]} outside a CALCULATE filter") if t[:in_filter] && !TI_TOTALS.key?(t[:fn])
      return result('D', 'time-intelligence CALCULATE carries extra filters') if t[:extra_filters].to_i > 0
      return result('D', 'USERELATIONSHIP combined with time intelligence') unless w.userel.empty?
      if subs.any? { |_, sr| sr['class'] == 'C' }
        return result('D', 'time intelligence applied over a time-intelligence measure')
      end
      base_nodes = t[:base]
      if base_nodes.length == 1 && base_nodes[0][0] == :id && w.vars[base_nodes[0][1]]
        base_nodes = w.vars[base_nodes[0][1]]
      end
      base = nil
      base_expr = nil
      if base_nodes.length == 1 && base_nodes[0][0] == :bare && ctx.measures.key?(base_nodes[0][1])
        base = base_nodes[0][1]
      else
        base_expr = lit_text(base_nodes)
      end
      dcol = first_col(t[:args][0] && TI_TOTALS.key?(t[:fn]) ? t[:args][1..-1].to_a.flatten(1) : t[:args].flatten(1))
      date_table = dcol && dcol[0]
      foreign = w.col.ti_refs.map(&:first).uniq.reject { |x| x == date_table }
      foreign -= w.col.direct_tables.to_a
      anchor = foreign.empty? ? 'axis' : 'as_of'
      days = pattern == 'rolling' ? extra : nil
      ti = { 'pattern' => pattern, 'base' => base, 'anchor' => anchor, 'days' => days }
      ti['unit'] = unit if unit
      ti['base_expr'] = base_expr if base_expr
      ti['date_table'] = date_table if date_table
    end
    sub_tis = subs.map { |_, sr| sr['ti'] }.compact
    if ti.nil? && !sub_tis.empty?
      keys = sub_tis.map { |x| [x['pattern'], x['anchor'], x['days'], x['base'], x['unit']] }.uniq
      return result('D', 'combines time-intelligence measures with different windows or bases') if keys.length > 1
      ti = sub_tis[0]
    elsif ti && !sub_tis.empty?
      return result('D', 'time intelligence applied over a time-intelligence measure')
    end

    # facts: tables read directly, plus the home of every sub-measure
    facts = Set.new(w.col.direct_tables)
    subs.each { |_, sr| facts << sr['home'] if sr['home'] }
    if facts.size > 1
      a = facts.to_a
      linked = a.combination(2).all? { |x, y| ctx.linked?(x, y) }
      return result('D', linked ? "reads more than one table directly (#{a.join(', ')}), not through RELATED" :
                                  "reaches facts #{a.join(' and ')} with no relationship path between them")
    end
    home = facts.first || table

    # related columns and relationships
    related = []
    (w.col.related + w.col.filters).each do |t, c|
      next if t == home
      p = ctx.path(home, t)
      return result('D', "filters or reads #{t}[#{c}], which has no relationship path from #{home}") if p.nil?
      related << { 'table' => t, 'column' => c, 'path' => p }
    end
    subs.each { |_, sr| related.concat(sr['related']) }
    related = related.uniq
    # I4: the columns a CALCULATE filter argument sets (R38): Power BI's value replaces any pick or axis member on them
    filter_columns = w.col.filters.map { |t, c| [t, c] }
    subs.each { |_, sr| filter_columns.concat(Array(sr['filter_columns'])) }
    filter_columns = filter_columns.uniq

    userels = w.userel.map { |r| PbiShapedModel.relationship_name(r) }
    w.userel.each do |r|
      return result('D', "USERELATIONSHIP #{r['fromTable']}[#{r['fromColumn']}] does not start at #{home}") if r['fromTable'] != home
    end
    subs.each { |_, sr| userels << sr['userel'] if sr['userel'] }
    userels = userels.uniq
    return result('D', "uses different inactive relationships (#{userels.join(', ')})") if userels.length > 1
    userel = userels.first

    klass = if ti then 'C'
            elsif !related.empty? || userel then 'B'
            else 'A'
            end
    reason = case klass
             when 'C'
               "#{ti['pattern']} time intelligence (#{ti['anchor']} anchor) over " +
                 (ti['base'] ? "[#{ti['base']}]" : "an inline aggregate on #{home}")
             when 'B'
               parts = []
               parts << "reads #{related.map { |r| "#{r['table']}[#{r['column']}]" }.uniq.join(', ')} through " \
                        "#{related.map { |r| r['path'].join(' > ') }.uniq.join(' / ')}" unless related.empty?
               parts << "uses inactive relationship #{userel}" if userel
               parts.join('; ')
             else "aggregates and arithmetic over #{home} columns only"
             end
    result(klass, reason, 'related' => related, 'userel' => userel, 'ti' => ti, 'home' => home,
                          'reach' => ctx.reach(home), 'filter_columns' => filter_columns)
  end

  def classify(table:, measure:, tmsl:, relationships:)
    Ctx.new(tmsl, relationships).classify(table, measure)
  end

  def classify_all(signals, tmsl, relationships)
    ctx = Ctx.new(tmsl, relationships)
    out = {}
    visible_measures(signals, tmsl).each do |vm|
      out[key_of(vm['table'], vm['measure'])] = ctx.classify(vm['table'], vm['measure'])
    end
    out
  end

  RANK = { 'A' => 0, 'B' => 1, 'C' => 2, 'D' => 3 }.freeze

  # classes key for a visual binding: "Table.Measure" exactly, or a bare measure name that is unique
  def class_for_ref(ref, classes)
    ref = ref.to_s
    return classes[ref] if classes.key?(ref)
    hits = classes.keys.select { |k| k.split('.', 2)[1] == ref }
    hits.length == 1 ? classes[hits[0]] : nil
  end

  # The single class a visual's measures need. D when its measures read different facts with no shared
  # path, or when they reach one dimension by different relationship paths (an order-date measure and
  # a ship-date measure on the same Date axis).
  def classify_visual(visual, classes)
    entries = []
    dims = []
    (visual['bindings'] || {}).each_value do |refs|
      Array(refs).each do |ref|
        e = class_for_ref(ref, classes)
        if e then entries << e
        else dims << ref.to_s
        end
      end
    end
    return 'A' if entries.empty?
    return 'D' if entries.any? { |e| e['class'] == 'D' }
    homes = entries.map { |e| [e['home'], Array(e['reach'])] }.uniq
    homes.combination(2).each do |(a, ra), (b, rb)|
      return 'D' unless a == b || ra.include?(b) || rb.include?(a)
    end
    paths = Hash.new { |h, k| h[k] = Set.new }
    entries.each { |e| e['related'].each { |r| paths[r['table']] << r['path'] } }
    return 'D' if paths.values.any? { |set| set.size > 1 }
    userels = entries.map { |e| e['userel'] }.uniq
    if userels.length > 1
      targets = userels.compact.map { |u| u.sub(/ \(.*\)\z/, '') }
      dim_tables = dims.map { |d| d.split('.', 2)[0] }
      return 'D' if targets.any? { |t| dim_tables.include?(t) }
    end
    entries.map { |e| e['class'] }.max_by { |c| RANK[c] }
  end
end
