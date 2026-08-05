# frozen_string_literal: true
#
# dim_canon.rb — ONE shared canonicalizer for dimension cell values, used by
# BOTH parity comparators (verify-parity.rb — Tableau CSV vs Sigma export — and
# verify-ground-truth.rb — warehouse ground truth vs Sigma export, PR-6).
#
# Extracted from verify-parity.rb so the two oracles cannot drift apart on what
# "the same bucket" means. Date-like dimension values canonicalize to a
# DAY-grain key ("YYYY-MM-DD") or month key ("YYYY-MM") so buckets compare
# equal across representations:
#
#   Sigma raw SQL      "2026-01-04T00:00:00.000"  → "2026-01-04"
#   Tableau weekly     "February 4, 2024"         → "2024-02-04"
#   Tableau monthly    "January 2026"             → "2026-01"
#   Tableau quarter    "2024 Q1"                  → "2024-01-01"
#   e2e defect list    "1/4/2026 12:00:00 AM"     → "2026-01-04"  (M/D/YYYY 12h)
#   e2e defect list    "Feb 4, 24"                → "2024-02-04"  (%b %d, %y)
#   plain              "1/4/2026"                 → "2026-01-04"
#
# Weekly grains MUST keep the underlying date value (bead s6fo) — the old
# collapse-day-1-to-month rule turned the "January 1" WEEK bucket into a month
# bucket and every weekly chart diverged. Month-label vs first-of-month is
# reconciled by the comparator's month-grain fallback, not here.
#
# Ruby 2.6-compatible, no dependencies.

module DimCanon
  MONTH_NUM = {
    'january' => 1, 'february' => 2, 'march' => 3, 'april' => 4, 'may' => 5, 'june' => 6,
    'july' => 7, 'august' => 8, 'september' => 9, 'october' => 10, 'november' => 11, 'december' => 12,
    'jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'jun' => 6,
    'jul' => 7, 'aug' => 8, 'sep' => 9, 'sept' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12
  }.freeze

  module_function

  # Two-digit years ("Feb 4, 24") pivot at 70: 00–69 → 2000s, 70–99 → 1900s
  # (matches the common spreadsheet/strptime %y convention).
  def expand_year(y)
    yi = y.to_i
    return yi if y.to_s.length == 4
    yi < 70 ? 2000 + yi : 1900 + yi
  end

  def canonicalize_dim(v)
    return v unless v.is_a?(String)
    s = v.strip
    # ISO datetime at midnight → day bucket (T or space separator)
    if (m = s.match(/\A(\d{4})-(\d{2})-(\d{2})[T ]00:00:00(?:\.0+)?(?:Z|[+-]\d{2}:?\d{2})?\z/))
      return "#{m[1]}-#{m[2]}-#{m[3]}"
    end
    # ISO date stays a day bucket
    return s if s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    # "1/4/2026 12:00:00 AM" (Tableau/Excel M/D/YYYY 12-hour midnight — e2e
    # defect list) and bare "1/4/2026" → day bucket. A NON-midnight time is a
    # real datetime bucket and is left alone (day-collapsing it would merge
    # distinct hourly buckets).
    if (m = s.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{2,4})(?:\s+(12:00:00\s*AM|0?0:00:00))?\z}i))
      return format('%04d-%02d-%02d', expand_year(m[3]), m[1].to_i, m[2].to_i)
    end
    # "February 4, 2024" / "Feb 4, 2024" / "Feb 4, 24" (%b %d, %y — e2e defect
    # list) — Tableau day/week labels
    if (m = s.match(/\A([A-Za-z]+)\s+(\d{1,2}),\s*(\d{2}|\d{4})\z/)) && (mnum = MONTH_NUM[m[1].downcase])
      return format('%04d-%02d-%02d', expand_year(m[3]), mnum, m[2].to_i)
    end
    # "January 2026" / "Jan 2026" → month bucket
    if (m = s.match(/\A([A-Za-z]+)\s+(\d{4})\z/)) && (mnum = MONTH_NUM[m[1].downcase])
      return format('%s-%02d', m[2], mnum)
    end
    # "2024 Q1" (Tableau quarter label) → first-of-quarter DAY bucket so it
    # compares equal to Sigma's DateTrunc("quarter") value ("2024-01-01T00:00:00"
    # canonicalizes to "2024-01-01" above). Added for window-function pivots
    # (WINPROBE MaxMin: Region × Quarter grid).
    if (m = s.match(/\A(\d{4})\s+Q([1-4])\z/i))
      return format('%s-%02d-01', m[1], ((m[2].to_i - 1) * 3) + 1)
    end
    # Already-canonical "YYYY-MM"
    return s if s.match?(/\A\d{4}-\d{2}\z/)
    v
  end

  # Truncate a canonical day key to its month bucket (month-grain fallback).
  def month_grain(v)
    v.is_a?(String) && v.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? v[0, 7] : v
  end

  # Convert all numerics to Float-rounded so Integer 11 and Float 11.0 compare
  # equal in a set, canonicalize date-like dim strings so equivalent buckets
  # match, and coerce purely-numeric STRINGS to floats (a scatter x-axis value
  # reads back as a string in the workbook query and must compare equal to the
  # numeric expected side; live ground-truth CSV rows arrive all-string).
  def round_row(row)
    row.map do |v|
      if v.is_a?(Numeric)
        v.to_f.round(2)
      elsif v.is_a?(String) && v.strip.match?(/\A-?\d+(\.\d+)?\z/)
        v.strip.to_f.round(2)
      else
        canonicalize_dim(v)
      end
    end
  end
end
