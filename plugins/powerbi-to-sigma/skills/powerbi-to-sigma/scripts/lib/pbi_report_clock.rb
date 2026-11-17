# frozen_string_literal: true

# pbi_report_clock.rb — one clock for "today" across a Power BI → Sigma migration.
#
# Power BI evaluates TODAY()/NOW() on ONE clock: the Power BI service uses UTC
# (Power BI Desktop uses the author's machine time zone). A naive migration
# evaluates it on TWO, both verified live (2026-11-16):
#   * Sigma Today()/Now() — Sigma inlines a literal computed in the Sigma account
#     time zone (e.g. to_timestamp_ltz('2026-11-16T00:00:00+00:00') on a UTC org).
#   * Warehouse CURRENT_DATE / CURRENT_TIMESTAMP — the warehouse SESSION time zone.
#     Sigma sets its own Snowflake sessions to UTC, but any other session (a
#     worksheet, the snow CLI, Power BI's connector) uses the account/user
#     TIMEZONE, America/Los_Angeles by default.
# For the hours between two midnights the clocks name different days, which moves
# rolling-N-day windows, days-since, MTD/YTD at a boundary and TODAY() tables.
#
# The REPORT CLOCK is one IANA time zone. This module rewrites every Sigma formula
# and warehouse SQL statement the migration emits to evaluate "today"/"now" in that
# zone explicitly (independent of the Sigma account and warehouse session zones),
# builds the same expression for the warehouse-SQL oracle, and decides whether a
# parity comparison of a today-relative chart is on one clock.
require 'date'
require 'json'
require 'time'

module PbiReportClock
  module_function

  DEFAULT_TIMEZONE = 'UTC'
  DEFAULT_SOURCE = 'default: the Power BI service evaluates TODAY()/NOW() in UTC'
  UTC_ALIASES = %w[UTC Etc/UTC GMT Etc/GMT Etc/Universal Universal Zulu Etc/Zulu Z Etc/GMT0 GMT0].freeze
  ZONEINFO_DIRS = [ENV['TZDIR'], '/usr/share/zoneinfo', '/usr/lib/zoneinfo', '/usr/share/lib/zoneinfo',
                   '/var/db/timezone/zoneinfo'].compact.freeze
  TZ_SHAPE = %r{\A[A-Za-z][A-Za-z0-9_+\-]*(?:/[A-Za-z0-9_+\-]+){0,2}\z}
  AS_OF_SHAPE = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
  DIALECTS = %w[snowflake databricks bigquery].freeze
  TZ_LOCK = Mutex.new

  # ---------------------------------------------------------------- timezones
  def zoneinfo_dir
    ZONEINFO_DIRS.find { |d| File.directory?(d) }
  end

  def valid_timezone?(tz)
    s = tz.to_s
    return false unless s.match?(TZ_SHAPE)
    return true if UTC_ALIASES.include?(s)

    dir = zoneinfo_dir
    # No tz database on this host: accept the IANA shape (the warehouse validates).
    return true if dir.nil?

    File.file?(File.join(dir, s))
  end

  def validate_timezone!(tz)
    return tz if valid_timezone?(tz)

    raise ArgumentError, "report timezone must be an IANA name such as UTC or America/New_York (got #{tz.inspect})"
  end

  def canonical(tz)
    return nil if tz.nil? || tz.to_s.strip.empty? || tz.to_s == 'unknown'

    UTC_ALIASES.include?(tz.to_s) ? 'UTC' : tz.to_s
  end

  def dialect!(dialect)
    d = dialect.to_s.empty? ? 'snowflake' : dialect.to_s.downcase
    raise ArgumentError, "unsupported warehouse dialect #{dialect.inspect}" unless DIALECTS.include?(d)

    d
  end

  # Runs the block with ENV['TZ'] set (Ruby re-reads TZ on assignment).
  def with_tz(tz)
    TZ_LOCK.synchronize do
      old = ENV['TZ']
      begin
        ENV['TZ'] = canonical(tz) || 'UTC'
        yield
      ensure
        ENV['TZ'] = old
      end
    end
  end

  def parse_instant(value)
    return value.utc if value.is_a?(Time)

    Time.iso8601(value.to_s).utc
  rescue ArgumentError
    Time.parse(value.to_s).utc
  end

  # Raised when a local date in a non-UTC zone cannot be computed on this host:
  # ENV['TZ'] with an unknown zone silently means UTC, so fail closed instead.
  class NoTzDatabase < StandardError; end

  def tz_database?(tz)
    return true if canonical(tz) == 'UTC'

    dir = zoneinfo_dir
    !dir.nil? && File.file?(File.join(dir, tz.to_s))
  end

  def require_tz_database!(tz)
    return if tz_database?(tz)

    raise NoTzDatabase, "no time zone database entry for #{tz.inspect} on this host (install tzdata or set TZDIR); " \
                        'the report day cannot be computed'
  end

  def local_date(instant, tz)
    require_tz_database!(tz)
    t = parse_instant(instant)
    with_tz(tz) { Time.at(t.to_r).localtime.to_date }
  end

  def midnight_utc(date, tz)
    require_tz_database!(tz)
    d = date.is_a?(Date) ? date : Date.parse(date.to_s)
    with_tz(tz) { Time.local(d.year, d.month, d.day).utc }
  end

  # The UTC interval on day `on` (a UTC date) during which zones a and b name
  # different calendar days, or nil when they never disagree.
  def disagreement_band(tz_a, tz_b, on:)
    a = midnight_utc(on, tz_a)
    b = midnight_utc(on, tz_b)
    return nil if a == b

    from, to = [a, b].minmax
    { 'from' => from.iso8601, 'to' => to.iso8601 }
  end

  # ---------------------------------------------------------- clock expressions
  def sigma_now(tz)
    %(ConvertTimezone(Now(), "#{validate_timezone!(tz)}"))
  end

  def sigma_today(tz)
    %(DateTrunc("day", #{sigma_now(tz)}))
  end

  def as_of_literal!(as_of)
    s = as_of.to_s
    raise ArgumentError, "as_of must be an ISO-8601 instant with a zone, e.g. 2026-11-17T03:00:00Z (got #{as_of.inspect})" unless s.match?(AS_OF_SHAPE)

    s
  end

  def now_sql(tz, dialect = 'snowflake', as_of: nil)
    z = validate_timezone!(tz)
    case dialect!(dialect)
    when 'snowflake'
      src = as_of ? "'#{as_of_literal!(as_of)}'::TIMESTAMP_TZ" : 'CURRENT_TIMESTAMP()'
      "CONVERT_TIMEZONE('#{z}', #{src})::TIMESTAMP_NTZ"
    when 'databricks'
      src = as_of ? "to_timestamp('#{as_of_literal!(as_of)}')" : 'current_timestamp()'
      "from_utc_timestamp(to_utc_timestamp(#{src}, current_timezone()), '#{z}')"
    when 'bigquery'
      as_of ? "DATETIME(TIMESTAMP '#{as_of_literal!(as_of)}', '#{z}')" : "CURRENT_DATETIME('#{z}')"
    end
  end

  def today_sql(tz, dialect = 'snowflake', as_of: nil)
    z = validate_timezone!(tz)
    case dialect!(dialect)
    when 'snowflake'
      src = as_of ? "'#{as_of_literal!(as_of)}'::TIMESTAMP_TZ" : 'CURRENT_TIMESTAMP()'
      "CAST(CONVERT_TIMEZONE('#{z}', #{src}) AS DATE)"
    when 'databricks'
      "CAST(#{now_sql(z, 'databricks', as_of: as_of)} AS DATE)"
    when 'bigquery'
      as_of ? "DATE(TIMESTAMP '#{as_of_literal!(as_of)}', '#{z}')" : "CURRENT_DATE('#{z}')"
    end
  end

  # ------------------------------------------------------------------- masking
  # Returns an array of booleans: true where the character is CODE (not inside a
  # string literal, quoted identifier, [bracket ref] or comment).
  def code_mask(text, mode)
    s = text.to_s
    mask = Array.new(s.length, true)
    i = 0
    while i < s.length
      c = s[i]
      if mode == :formula && c == '"'
        j = i + 1
        j += (s[j] == '\\' ? 2 : 1) while j < s.length && s[j] != '"'
        (i..[j, s.length - 1].min).each { |k| mask[k] = false }
        i = j + 1
      elsif mode == :formula && c == '['
        j = s.index(']', i + 1) || (s.length - 1)
        (i..j).each { |k| mask[k] = false }
        i = j + 1
      elsif mode == :dax && (c == '"' || c == "'" || c == '[')
        close = c == '[' ? ']' : c
        j = s.index(close, i + 1) || (s.length - 1)
        (i..j).each { |k| mask[k] = false }
        i = j + 1
      elsif mode == :sql && ["'", '"', '`'].include?(c)
        j = i + 1
        while j < s.length
          if (s[j] == c && s[j + 1] == c) || (s[j] == '\\' && c == "'")
            j += 2
            next
          end
          break if s[j] == c

          j += 1
        end
        (i..[j, s.length - 1].min).each { |k| mask[k] = false }
        i = j + 1
      elsif mode == :sql && s[i, 2] == '--'
        j = s.index("\n", i) || s.length
        (i...j).each { |k| mask[k] = false }
        i = j
      elsif mode == :sql && s[i, 2] == '/*'
        j = s.index('*/', i + 2)
        j = j ? j + 1 : s.length - 1
        (i..j).each { |k| mask[k] = false }
        i = j + 1
      else
        i += 1
      end
    end
    mask
  end

  # Replace regex matches that START in code. The block gets (MatchData, prefix)
  # and returns the replacement, or nil to keep the match.
  def replace_in_code(text, regex, mode)
    s = text.to_s
    mask = code_mask(s, mode)
    out = +''
    pos = 0
    s.scan(regex) do
      m = Regexp.last_match
      next unless mask[m.begin(0)]

      rep = yield(m, s[0...m.begin(0)])
      next if rep.nil?

      out << s[pos...m.begin(0)] << rep
      pos = m.end(0)
    end
    out << s[pos..]
    out
  end

  # ------------------------------------------------------------ Sigma formulas
  BARE_CLOCK_RE = /\b(Today|Now)\s*\(\s*\)/i
  # ConvertTimezone(Now(), "<to>"[, "<from>"]) — an explicitly zoned clock, pinned by
  # an earlier run or authored. Never re-zoned; scan reports it when <to> is not
  # the report zone.
  ZONED_NOW_RE = /ConvertTimezone\(\s*Now\(\s*\)\s*,\s*"([^"]*)"/i

  def pinned_now_prefix?(prefix)
    prefix.match?(/ConvertTimezone\(\s*\z/i)
  end

  def pin_formula(formula, tz)
    z = validate_timezone!(tz)
    replace_in_code(formula.to_s, BARE_CLOCK_RE, :formula) do |m, prefix|
      if m[1].casecmp('now').zero?
        pinned_now_prefix?(prefix) ? nil : sigma_now(z)
      else
        sigma_today(z)
      end
    end
  end

  def bare_formula_clocks(formula)
    s = formula.to_s
    mask = code_mask(s, :formula)
    found = []
    s.scan(BARE_CLOCK_RE) do
      m = Regexp.last_match
      next unless mask[m.begin(0)]
      next if m[1].casecmp('now').zero? && pinned_now_prefix?(s[0...m.begin(0)])

      found << (m[1].casecmp('now').zero? ? 'Now' : 'Today')
    end
    found
  end

  def formula_zones(formula)
    s = formula.to_s
    mask = code_mask(s, :formula)
    s.to_enum(:scan, ZONED_NOW_RE).map { Regexp.last_match }.select { |m| mask[m.begin(0)] }.map { |m| m[1] }
  end

  def today_relative_formula?(formula)
    s = formula.to_s
    mask = code_mask(s, :formula)
    s.to_enum(:scan, BARE_CLOCK_RE).any? { mask[Regexp.last_match.begin(0)] }
  end

  def today_relative_dax?(dax)
    s = dax.to_s
    mask = code_mask(s, :dax)
    s.to_enum(:scan, /\b(TODAY|NOW|UTCTODAY|UTCNOW)\s*\(/i).any? { mask[Regexp.last_match.begin(0)] }
  end

  # ------------------------------------------------------------------------ SQL
  SQL_CLOCK_RE = /\b(CURRENT_DATE|CURRENT_TIMESTAMP|CURRENT_DATETIME|GETDATE|LOCALTIMESTAMP|SYSDATE|SYSTIMESTAMP|NOW)\b(\s*\(\s*\d*\s*\))?/i
  # Function-only names: without "(" they are ordinary identifiers (a column named now).
  PAREN_REQUIRED = %w[NOW GETDATE SYSDATE SYSTIMESTAMP].freeze
  # Explicitly zoned clocks (capture = the zone "today" is evaluated in).
  SQL_ZONE_RES = [
    /CONVERT_TIMEZONE\(\s*'([^']*)'\s*,\s*CURRENT_TIMESTAMP\b/i,              # Snowflake 2-arg
    /CONVERT_TIMEZONE\(\s*'[^']*'\s*,\s*'([^']*)'\s*,\s*CURRENT_TIMESTAMP\b/i, # Snowflake 3-arg (target)
    /current_timezone\(\s*\)\s*\)\s*,\s*'([^']*)'\s*\)/i,                     # Databricks (this module's form)
    /from_utc_timestamp\(\s*current_timestamp\(\s*\)\s*,\s*'([^']*)'\s*\)/i,   # Databricks (authored)
    /\bCURRENT_DATE(?:TIME)?\s*\(\s*'([^']*)'\s*\)/i                           # BigQuery
  ].freeze

  def pin_dialect(wh_type)
    t = wh_type.to_s.downcase.strip
    return 'snowflake' if t.empty? || t.include?('snowflake')
    return 'databricks' if t.include?('databricks') || t.include?('spark')
    return 'bigquery' if t.include?('bigquery')

    nil # no timezone-explicit form here: SQL is left as written and reported unpinned
  end

  def supported_dialect(dialect)
    d = dialect.to_s.downcase
    DIALECTS.include?(d) ? d : nil
  end

  def pinned_sql_prefix?(prefix)
    prefix.match?(/CONVERT_TIMEZONE\(\s*'[^']*'\s*,\s*(?:'[^']*'\s*,\s*)?\z/i) ||
      prefix.match?(/(?:to_utc_timestamp|from_utc_timestamp)\(\s*\z/i)
  end

  def zoned_call?(text, match)
    # BigQuery CURRENT_DATE('UTC') / CURRENT_DATETIME('x'): an explicit zone argument.
    return false if match[2]

    text[match.end(0)..].to_s.match?(/\A\s*\(\s*'/)
  end

  # Not a clock call: an alias (AS now), a qualified column (t.now), a function-only
  # name without parentheses, an explicit zone argument, or a timestamp already inside
  # a zone conversion (2- or 3-arg CONVERT_TIMEZONE, Databricks utc conversions).
  def skip_clock_match?(text, match, prefix, dialect)
    name = match[1].upcase
    return true if PAREN_REQUIRED.include?(name) && match[2].nil?
    return true if prefix.match?(/(?:\.|\bAS)\s*\z/i)
    return true if zoned_call?(text, match)
    return true if name == 'CURRENT_TIMESTAMP' && pinned_sql_prefix?(prefix)
    # BigQuery CURRENT_TIMESTAMP is an absolute UTC instant, not a session clock.
    return true if dialect == 'bigquery' && name == 'CURRENT_TIMESTAMP'

    false
  end

  def pin_sql(sql, tz, dialect = 'snowflake')
    z = validate_timezone!(tz)
    d = dialect!(dialect)
    s = sql.to_s
    replace_in_code(s, SQL_CLOCK_RE, :sql) do |m, prefix|
      next nil if skip_clock_match?(s, m, prefix, d)

      name = m[1].upcase
      # (if/elsif, not pattern matching: the documented Ruby floor is 2.6)
      if name == 'CURRENT_DATE'
        today_sql(z, d)
      elsif d == 'bigquery'
        name == 'CURRENT_DATETIME' ? now_sql(z, d) : nil
      elsif %w[CURRENT_TIMESTAMP GETDATE LOCALTIMESTAMP NOW].include?(name)
        now_sql(z, d)
      end # SYSDATE / SYSTIMESTAMP: a UTC clock — reported by session_clock_refs, not guessed
    end
  end

  def session_clock_refs(sql, dialect = nil)
    s = sql.to_s
    mask = code_mask(s, :sql)
    d = supported_dialect(dialect)
    found = []
    s.scan(SQL_CLOCK_RE) do
      m = Regexp.last_match
      next unless mask[m.begin(0)]
      next if skip_clock_match?(s, m, s[0...m.begin(0)], d)

      found << m[1].upcase
    end
    found.uniq
  end

  def sql_zones(sql)
    s = sql.to_s
    mask = code_mask(s, :sql)
    SQL_ZONE_RES.flat_map do |re|
      s.to_enum(:scan, re).map { Regexp.last_match }.select { |m| mask[m.begin(0)] }.map { |m| m[1] }
    end
  end

  def sql_pinned?(sql)
    !sql_zones(sql).empty?
  end

  # ------------------------------------------------------------- documents
  def document_root(doc)
    doc['document'] || doc['contents'] || doc
  end

  def each_element(doc)
    root = document_root(doc)
    els = Array(root['elements'])
    Array(root['pages']).each { |p| els += Array(p['elements']) if p.is_a?(Hash) }
    els.select { |e| e.is_a?(Hash) }.each { |e| yield e }
  end

  def walk_formulas(node, path, &blk)
    case node
    when Hash
      node.each do |k, v|
        if k == 'formula' && v.is_a?(String)
          blk.call(node, k, "#{path}.#{k}")
        else
          walk_formulas(v, "#{path}.#{k}", &blk)
        end
      end
    when Array
      node.each_with_index { |v, i| walk_formulas(v, "#{path}[#{i}]", &blk) }
    end
  end

  def element_label(el)
    el['name'] || el['id']
  end

  # Pins every bare formula clock and (for a supported dialect) every bare SQL
  # session clock in a data-model spec or workbook document IN PLACE. Explicit
  # zones are left as written. Returns the audit record for report-clock.json.
  def apply!(doc, timezone:, dialect: 'snowflake', scope: 'document')
    z = validate_timezone!(timezone)
    d = supported_dialect(dialect)
    pinned = []
    already = 0
    each_element(doc) do |el|
      walk_formulas(el, '') do |holder, key, path|
        before = holder[key]
        after = pin_formula(before, z)
        if after != before
          pinned << { 'element' => element_label(el), 'field' => path.sub(/\A\./, ''), 'kind' => 'formula',
                      'clocks' => bare_formula_clocks(before), 'before' => before, 'after' => after }
          holder[key] = after
        elsif today_relative_formula?(after)
          already += 1
        end
      end
      src = el['source']
      next unless d && src.is_a?(Hash) && src['kind'] == 'sql' && src['statement'].is_a?(String)

      before = src['statement']
      after = pin_sql(before, z, d)
      if after != before
        pinned << { 'element' => element_label(el), 'field' => 'source.statement', 'kind' => 'sql',
                    'clocks' => session_clock_refs(before, d), 'before' => before, 'after' => after }
        src['statement'] = after
      elsif sql_pinned?(after)
        already += 1
      end
    end
    { 'scope' => scope, 'timezone' => z, 'dialect' => d || 'unsupported', 'pinned' => pinned,
      'already_pinned' => already, 'unpinned' => scan(doc, report_timezone: z, dialect: d) }
  end

  # Clock sites NOT on the report clock (read-only): bare Sigma Today()/Now(),
  # bare SQL session clocks, and — when report_timezone is given — explicitly
  # zoned clocks whose zone is not the report zone (each carries 'zone').
  def scan(doc, report_timezone: nil, dialect: nil)
    report = canonical(report_timezone)
    d = supported_dialect(dialect)
    sites = []
    each_element(doc) do |el|
      label = element_label(el)
      walk_formulas(el, '') do |holder, key, path|
        field = path.sub(/\A\./, '')
        bare_formula_clocks(holder[key]).uniq.each do |clock|
          sites << { 'element' => label, 'field' => field, 'kind' => 'formula', 'clock' => clock }
        end
        next unless report

        formula_zones(holder[key]).uniq.each do |zone|
          next if canonical(zone) == report

          sites << { 'element' => label, 'field' => field, 'kind' => 'formula', 'clock' => 'ConvertTimezone', 'zone' => zone }
        end
      end
      src = el['source']
      next unless src.is_a?(Hash) && src['statement'].is_a?(String)

      session_clock_refs(src['statement'], d).each do |clock|
        sites << { 'element' => label, 'field' => 'source.statement', 'kind' => 'sql', 'clock' => clock }
      end
      next unless report

      sql_zones(src['statement']).uniq.each do |zone|
        next if canonical(zone) == report

        sites << { 'element' => label, 'field' => 'source.statement', 'kind' => 'sql', 'clock' => 'zoned', 'zone' => zone }
      end
    end
    sites
  end

  # ------------------------------------------------------------ clock record
  def record(timezone:, source: DEFAULT_SOURCE, dialect: 'snowflake', data_model: nil, workbook: nil,
             sigma_org_timezone: nil, warehouse_session_timezone: nil)
    z = validate_timezone!(timezone)
    d = supported_dialect(dialect)
    slim = lambda do |audit|
      next nil unless audit

      audit.merge('pinned' => Array(audit['pinned']).map { |p| p.reject { |k, _| %w[before after].include?(k) } })
    end
    {
      'schema_version' => 1,
      'report_timezone' => z,
      'report_timezone_source' => source,
      'dialect' => d || 'unsupported',
      'sigma_today' => sigma_today(z),
      'warehouse_today_sql' => d ? today_sql(z, d) : nil,
      'sigma_org_timezone' => sigma_org_timezone || 'unknown',
      'warehouse_session_timezone' => warehouse_session_timezone || 'unknown',
      'data_model' => slim.call(data_model),
      'workbook' => slim.call(workbook),
      'notes' => [
        'Power BI calculated tables and columns that use TODAY() are evaluated at dataset REFRESH; Sigma evaluates ' \
        'the migrated expression at query time (always the current report day).',
        'A materialized element that depends on today is frozen at its materialization run; re-materialize it ' \
        'after each report-timezone midnight.'
      ]
    }
  end

  def merge_record!(path, section, audit)
    rec = File.exist?(path) ? JSON.parse(File.read(path)) : nil
    return nil unless rec

    slim = audit.merge('pinned' => Array(audit['pinned']).map { |p| p.reject { |k, _| %w[before after].include?(k) } })
    rec[section] = slim
    File.write(path, JSON.pretty_generate(rec))
    rec
  end

  # ------------------------------------------------------------ parity check
  # Sigma's clock for this build: the report zone when nothing is unpinned, else
  # the clock the unpinned sites use (account zone for formulas, warehouse
  # session zone for SQL).
  def sigma_clock(clock)
    report = canonical(clock['report_timezone'])
    unpinned = Array(clock.dig('data_model', 'unpinned')) + Array(clock.dig('workbook', 'unpinned'))
    return report if unpinned.empty?

    zones = unpinned.map do |site|
      if site['zone']
        canonical(site['zone'])
      elsif site['kind'] == 'sql'
        canonical(clock['warehouse_session_timezone'])
      else
        canonical(clock['sigma_org_timezone'])
      end
    end
    return 'unknown' if zones.any?(&:nil?)

    zones.uniq.size == 1 ? zones.first : "mixed(#{zones.uniq.join(',')})"
  end

  def parity_verdict(clock:, oracle_clock:, expected_as_of:, actual_as_of:)
    unless clock.is_a?(Hash) && clock['report_timezone']
      return { 'ok' => false, 'reason' => 'no report-clock.json: rerun migrate-powerbi.rb (it records the report clock) ' \
                                          'or pass --report-clock; a today-relative chart cannot be compared on an unknown clock' }
    end

    report = canonical(clock['report_timezone'])
    sigma = sigma_clock(clock)
    oracle = canonical(oracle_clock.is_a?(Hash) ? oracle_clock['timezone'] : nil) || 'unknown'
    base = { 'report_timezone' => report, 'sigma_clock' => sigma, 'oracle_clock' => oracle,
             'oracle_kind' => oracle_clock.is_a?(Hash) ? oracle_clock['kind'] : nil }
    if sigma != report || oracle != report
      return base.merge('ok' => false,
                        'reason' => "today is evaluated on two clocks: Sigma=#{sigma}, oracle=#{oracle} " \
                                    "(#{base['oracle_kind'] || 'unknown oracle'}), report=#{report}. Pin both to " \
                                    'the report clock (migrate-powerbi.rb --report-timezone; build-oracle-sql.rb report_timezone)')
    end
    if expected_as_of.nil? || actual_as_of.nil?
      return base.merge('ok' => false, 'reason' => 'oracle or actuals as-of time unknown; cannot prove one report day')
    end

    begin
      d1 = local_date(expected_as_of, report)
      d2 = local_date(actual_as_of, report)
    rescue NoTzDatabase => e
      return base.merge('ok' => false, 'reason' => e.message)
    end
    if d1 != d2
      return base.merge('ok' => false, 'report_day' => nil,
                        'reason' => "oracle (#{expected_as_of}) and Sigma actuals (#{actual_as_of}) straddle midnight in " \
                                    "#{report} (#{d1} vs #{d2}); rerun both sides on one report day")
    end

    base.merge('ok' => true, 'report_day' => d1.to_s, 'reason' => "one clock (#{report}), report day #{d1}")
  end
end
