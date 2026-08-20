# frozen_string_literal: true
# pbi_timeintel_route.rb — provenance guard for the time-intel fallback router in
# migrate-powerbi.rb.
#
# The converter turns DAX SAMEPERIODLASTYEAR / TOTALYTD measures into synthesized
# grouped elements (DateLookback / CumulativeSum). A fallback pass routes any
# REMAINING time-intel-shaped measure (one with no element of its own) to "the
# best-matching time-intel column". That pass used to scan ALL synthesized
# elements with no regard for which FACT they belong to.
#
# Live failure (KitchenSink run-2): "PY Incident Count" is a SAFETY_INCIDENTS
# measure, but the only synthesized elements were ABSENCE-derived ("YTD Absence
# Hours" / "PY Absence Hours", both sourcing ABSENCE_RECORDS View). The router
# bound the prior-year INCIDENT count to the absence-hours YTD column —
# `SAFETY_INCIDENTS.PY Incident Count -> [YTD Absence Hours/Hours YTD]` — i.e.
# semantically garbage numbers from an unrelated fact.
#
# Guard: a prior-year/YTD measure may only borrow a time-intel element built from
# its OWN fact. If no same-fact element exists, DON'T route — leave it unresolved
# so it degrades honestly into coverage.json, never cross-wired to another table.
module PbiTimeIntelRoute
  module_function

  TIME_INTEL_RE =
    /\b(SAMEPERIODLASTYEAR|TOTALYTD|TOTALQTD|TOTALMTD|DATESYTD|DATEADD|PARALLELPERIOD|PREVIOUSYEAR|PREVIOUSMONTH|PREVIOUSQUARTER)\b/i

  # base fact of a synthesized time-intel element = the table its source View
  # denormalizes ("ABSENCE_RECORDS View" -> "ABSENCE_RECORDS"). A plain table name
  # passes through unchanged.
  def fact_of(view_or_table_name)
    view_or_table_name.to_s.sub(/\s+View\z/i, '').strip
  end

  # may a measure on `measure_table` borrow a time-intel element whose base fact is
  # `ti_fact`? Only when they are the SAME fact (whitespace/case-insensitive).
  def same_fact?(measure_table, ti_fact)
    a = norm(measure_table)
    b = norm(ti_fact)
    !a.empty? && a == b
  end

  # Classify a remaining measure before selecting a synthesized time-intel
  # column. Prefer the measure's explicit semantic name over broad expression
  # heuristics: a "Net Revenue PY" expression commonly contains ALL([Year]), but
  # that is still a prior-year value, not the synthesized YoY percentage.
  def measure_shape(measure_name, expression)
    name = measure_name.to_s
    expr = expression.to_s
    return :yoy if name =~ /YoY|Y\/Y|growth/i
    return :ytd if name =~ /\bYTD\b/i
    return :prior if name =~ /\b(PY|Prior Year|Last Year|LY)\b/i
    return :generic if expr =~ TIME_INTEL_RE
    return :yoy if expr =~ /ALL\s*\([^)]*\[Year\]/i

    nil
  end

  # A reused Sigma time-intel element may have been renamed since conversion
  # ("Net Revenue PY" -> "Revenue by Year"), so no source measure name maps back
  # to its original table. Preserve the source element's fact as the fallback
  # routing table for co-locating base values and period dimensions.
  def routing_table(original_table, time_intel_fact)
    original = original_table.to_s.strip
    return original unless original.empty?

    time_intel_fact.to_s.strip
  end

  def norm(str)
    str.to_s.gsub(/\s+/, '').downcase
  end
end
