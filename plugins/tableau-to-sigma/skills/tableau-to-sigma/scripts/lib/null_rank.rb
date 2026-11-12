# frozen_string_literal: true

# null_rank.rb — Tableau's RANK skips nulls; Sigma's Rank does not.
#
# Sigma (help.sigmacomputing.com/docs/rank): "Null values are ranked last,
# after all non-Null values when sorted ascending, and before all non-Null
# values when sorted descending." There is no null-handling argument. Live
# Stress 4 check: Store Rank Table's Rank(Sum(Net Revenue), "desc") gave the
# 0-order Phoenix Outlet (NULL revenue) rank 1 and shifted every store down
# one; Tableau leaves Phoenix's rank blank and ranks the others 1..14. The
# Top-N rank helper had the same flaw (a NULL member took a keep slot).
#
# rewrite() turns every Rank / RankDense / RankPercentile(E, dir) call into
#   If(IsNull(E), Null, Fn(<E ordered nulls-last>, "asc"))
# where a DESC rank ranks -(E) ascending (nulls stay last; ties identical),
# so a NULL measure gets a NULL rank and consumes no position. Calls with no
# argument (rank follows the table sort) are left alone; a DESC rank whose
# operand is not provably numeric (Min/Max/bare refs may be text or dates;
# -(E) needs a number) is left alone too. Idempotent.
module NullRank
  FN_RE = /\b(RankPercentile|RankDense|Rank)\(/.freeze

  module_function

  # index of the paren closing the one opened at s[open_i]
  def close_paren(s, open_i)
    depth = 0
    in_str = false
    i = open_i
    while i < s.length
      ch = s[i]
      if in_str
        in_str = false if ch == '"'
      elsif ch == '"' then in_str = true
      elsif ch == '(' then depth += 1
      elsif ch == ')'
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    nil
  end

  def split_args(body)
    args = []
    depth = 0
    in_str = false
    cur = +''
    body.each_char do |ch|
      if in_str
        in_str = false if ch == '"'
      elsif ch == '"' then in_str = true
      elsif ch == '(' || ch == '[' then depth += 1
      elsif ch == ')' || ch == ']' then depth -= 1
      elsif ch == ',' && depth.zero?
        args << cur.strip
        cur = +''
        next
      end
      cur << ch
    end
    args << cur.strip unless cur.strip.empty?
    args
  end

  NUMERIC_AGG_RE = /\b(?:Sum|Avg|Count|CountDistinct|CountIf|Median|Percentile\w*|StdDev\w*|Variance\w*)\(/i.freeze

  # Negating needs a NUMBER: a numeric aggregate, or the Top-N rank helper's
  # [Rank Measure] (always built from the ranked measure). Min/Max/bare refs
  # may be text or dates — left alone rather than risk an invalid formula.
  def numeric_operand?(e)
    return false if e =~ /\bText\(/i
    e =~ NUMERIC_AGG_RE || e =~ %r{\A\[(?:[^\]]*/)?Rank Measure\]\z} ? true : false
  end

  def rewrite(formula)
    s = formula.to_s
    return s unless s =~ FN_RE
    out = +''
    pos = 0
    while (m = FN_RE.match(s, pos))
      start = m.begin(0)
      open_i = m.end(0) - 1
      close_i = close_paren(s, open_i)
      break unless close_i
      out << s[pos...start]
      call = s[start..close_i]
      args = split_args(s[(open_i + 1)...close_i])
      e = args[0].to_s
      dir = args[1].to_s.delete('"').strip.downcase
      dir = 'asc' if dir.empty?
      guarded = out.end_with?("If(IsNull(#{e.sub(/\A-\((.*)\)\z/, '\1')}), Null, ")
      if e.empty? || args.size > 2 || !%w[asc desc].include?(dir) || guarded ||
         (dir == 'desc' && !numeric_operand?(e))
        out << rewrite_inner(call, m[1])
      else
        operand = dir == 'desc' ? "-(#{e})" : e
        out << "If(IsNull(#{e}), Null, #{m[1]}(#{operand}, \"asc\"))"
      end
      pos = close_i + 1
    end
    out << s[pos..].to_s
    out
  end

  # an unrewritten call may still contain rank calls in its arguments
  def rewrite_inner(call, fn)
    inner = call[(fn.length + 1)...-1]
    "#{fn}(#{rewrite(inner)})"
  end

  # Every column formula of every element (legacy pages view or flat
  # elements). Returns the number of columns changed.
  def apply!(spec)
    els = Array(spec['pages']).flat_map { |p| Array(p['elements']) } + Array(spec['elements'])
    n = 0
    els.uniq(&:object_id).each do |el|
      Array(el['columns']).each do |c|
        next unless c.is_a?(Hash) && c['formula'].to_s =~ FN_RE
        nf = rewrite(c['formula'])
        next if nf == c['formula']
        c['formula'] = nf
        n += 1
      end
    end
    n
  end
end
