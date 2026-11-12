# frozen_string_literal: true
#
# measure_precision.rb — plan C11b: a measure's number precision follows the
# SOURCE (Tableau) format, never a fixed default. Display-only; values and
# formulas are untouched.
#
# The builder stamps fixed-precision percent formats on window/share measures
# (PercentOfTotal -> ',.2%', attainment -> ',.1%', ...) AFTER the source format
# was resolved, clobbering it: a source `p0.0%` printed 2dp. `resolve` keeps the
# default's KIND (percent) but takes the whole format from the source when the
# source is itself a percent format (so its decimals win). With no usable
# source format the default is returned unchanged.
#
# displayNullAs (C1 / a 4th source segment) already on the column survives.
module MeasurePrecision
  module_function

  PERCENT_RE = /%\z/.freeze

  def percent?(fmt)
    fmt.is_a?(Hash) && fmt['kind'] == 'number' && fmt['formatString'].to_s =~ PERCENT_RE ? true : false
  end

  # source_fmt: Sigma format hash translated from the source (or nil).
  # default_fs: the d3 percent formatString the builder would have used.
  # existing:   the column's current format hash (only displayNullAs is kept).
  def percent_format(source_fmt, default_fs, existing = nil)
    out = percent?(source_fmt) ? source_fmt.dup : { 'kind' => 'number', 'formatString' => default_fs }
    if existing.is_a?(Hash) && existing.key?('displayNullAs') && !out.key?('displayNullAs')
      out['displayNullAs'] = existing['displayNullAs']
    end
    out
  end
end
