# frozen_string_literal: true
#
# PbiDateFields -- which fields of a date table provably equal a calendar truncation (opt-in `--model-shape pbi`, I2).
#
# A time-intelligence element exposes the date levels of its grain as columns: DateTrunc("year"|"quarter"|"month"|"day",
# <date>) (a date) and, for the integer fields, Year()/Quarter()/Month() of it. A Power BI date-table field may be bound to
# one of those columns only when its values are provably that column's values:
#
#   date form  a date column: the table's own `Date`/`Day` (dateTime), or a calculated column whose DAX is a calendar
#              truncation of [Date] (DATE(YEAR([Date]), MONTH([Date]), 1), STARTOFMONTH/QUARTER/YEAR([Date]), DATE(YEAR([Date]), 1, 1))
#   int form   an integer Year / Quarter / Month Number field (calendar numbering)
#
# Everything else (Fiscal Year, Fiscal Quarter, a physical Month Start with no expression, week fields, names, labels, a
# column of an unknown meaning) has no provable calendar column: nil. Without the model's column (`column` nil) the
# name alone decides, as before, minus every fiscal/period name.
module PbiDateFields
  module_function

  UNITS = %w[day month quarter year].freeze
  NOT_CALENDAR = /fiscal|\bfy\b|\bfq\b|week|period|iso|offset|relative|rank|sort|label|name|text|abbr|short|key|\bid\b/i.freeze
  INT_TYPES = %w[int64 integer whole int].freeze
  DATE_TYPES = %w[datetime date].freeze

  # {'unit' => 'day'|'month'|'quarter'|'year', 'form' => 'date'|'int'} or nil.
  def info(name, column = nil)
    n = name.to_s.strip
    return nil if n =~ NOT_CALENDAR
    type = column && column['dataType'].to_s.downcase
    expr = column && column['expression']
    expr = expr.join("\n") if expr.is_a?(Array)
    if column && !expr.to_s.strip.empty?
      u = expression_unit(expr.to_s)
      return u ? { 'unit' => u, 'form' => 'date' } : nil
    end
    if n =~ /\A(date|day)\z/i
      return nil if column && !DATE_TYPES.include?(type)
      return { 'unit' => 'day', 'form' => 'date' }
    end
    # a physical month/quarter/year START column cannot be proven from a name; the model must say so (an expression)
    if n =~ /\A(calendar\s+)?year(\s+(number|num|no\.?))?\z/i
      return nil if column && !INT_TYPES.include?(type)
      return { 'unit' => 'year', 'form' => 'int' }
    end
    if n =~ /\A(calendar\s+)?quarter(\s+(number|num|no\.?))?\z/i
      return nil if column && !INT_TYPES.include?(type)
      return { 'unit' => 'quarter', 'form' => 'int' }
    end
    if n =~ /\A(calendar\s+)?month(\s+(number|num|no\.?))?\z/i
      return nil if column && !INT_TYPES.include?(type)
      return { 'unit' => 'month', 'form' => 'int' }
    end
    # name-only fallback (no model column): the usual start-of-period names
    if column.nil? && n =~ /\A(month|quarter|year)\s*start\z/i
      return { 'unit' => n[/\A\w+/].downcase, 'form' => 'date' }
    end
    nil
  end

  # The calendar unit a calculated date column's DAX truncates [Date] to, else nil.
  def expression_unit(expr)
    e = expr.gsub(/\s+/, ' ').strip
    d = "(?:'?Date'?\\s*)?\\[Date\\]"
    return 'month' if e =~ /\ADATE\(\s*YEAR\(\s*#{d}\s*\)\s*,\s*MONTH\(\s*#{d}\s*\)\s*,\s*1\s*\)\z/i
    return 'year' if e =~ /\ADATE\(\s*YEAR\(\s*#{d}\s*\)\s*,\s*1\s*,\s*1\s*\)\z/i
    return 'month' if e =~ /\ASTARTOFMONTH\(\s*#{d}\s*\)\z/i
    return 'quarter' if e =~ /\ASTARTOFQUARTER\(\s*#{d}\s*\)\z/i
    return 'year' if e =~ /\ASTARTOFYEAR\(\s*#{d}\s*\)\z/i
    nil
  end

  # {[table downcased, column downcased] => info} for every column of the named date tables of `tmsl`.
  def infos(tmsl, tables)
    model = (tmsl || {})['model'] || tmsl || {}
    wanted = Array(tables).map { |t| t.to_s.downcase }
    out = {}
    Array(model['tables']).each do |t|
      next unless wanted.include?(t['name'].to_s.downcase)
      Array(t['columns']).each do |c|
        next if c['type'] == 'rowNumber'
        i = info(c['name'], c)
        out[[t['name'].to_s.downcase, c['name'].to_s.downcase]] = i if i
      end
    end
    out
  end
end
