# frozen_string_literal: true
#
# integer_dim.rb — PR-18: integer-coded dimension detection + decode-to-text
# routing helpers (tableau-to-sigma-local; NOT a shared lib).
#
# THE FAILURE CLASS (field: a multi-page session + Twin C). An INTEGER warehouse column
# (STORE_KEY / PROMO_KEY / SITE_KEY) used in Tableau as a DISCRETE dimension on
# a quick-filter shelf. Sigma list/dropdown controls source their option values
# as STRINGS, so a list control whose filter TARGET is the raw integer column is
# accepted by POST/PUT (200) then reads back `filters: null` — the filter is
# SILENTLY STRIPPED (control-parity.md "list-control targets on NUMERIC columns
# are silently stripped"; same class as the datetime strip). The dashboard ships
# a control that filters nothing.
#
# THE SANCTIONED WORKAROUND (proven by hand in Twin C's runs, gen-wb-spec.rb):
# add a `Text([<col>])`-decoded helper column on the element the control targets
# and bind BOTH the control's filter target columnId AND its value-source
# columnId to the decoded column. The list then sources/filters STRING values
# and the filter survives.
#
# This module carries only the pure, testable DECISIONS + string builders; the
# routing lives in build-charts-from-signals.rb and the master-column injection
# in migrate-tableau.rb (a master-rooted control's decode column must live on
# the master so the filter propagates to every chart sourcing from it).
module IntegerDim
  module_function

  # Tableau datatypes that are integer-coded. Tableau writes `integer` for
  # whole-number columns; `real` is a continuous measure (never a discrete
  # dimension key) so it is deliberately NOT included.
  INTEGER_DATATYPES = %w[integer].freeze

  # Filter kinds that enumerate DISCRETE members (a list/dropdown control) — the
  # only shapes where the numeric-target strip bites. A `number-range` filter on
  # an integer column is a quantitative slider (no strip), so it is excluded.
  DISCRETE_FILTER_KINDS = %w[list list+condition wildcard].freeze

  # Sigma controlTypes that source a STRING option list and thus strip a numeric
  # filter target (the decode is required for these). `segmented` is a value-list
  # too; `number`/`number-range`/`slider`/`date*`/`switch` are not.
  DECODE_CONTROL_TYPES = %w[list segmented hierarchy].freeze

  # Is this normalized filter (parse-twb-layout normalize_filter output) an
  # integer-coded column used as a DISCRETE dimension? Two signals, per the plan:
  #   (a) the .twb marks it integer-typed AND used discretely (a categorical/list
  #       filter enumerates discrete members, OR the column role is 'dimension');
  # The warehouse-cardinality probe (probe-int-dim-cardinality.rb) is the
  # OPTIONAL confirmation — detection stands on the .twb alone.
  def integer_dim_filter?(filter)
    return false unless filter.is_a?(Hash)
    dt = filter['datatype'].to_s.strip.downcase
    return false unless INTEGER_DATATYPES.include?(dt)
    DISCRETE_FILTER_KINDS.include?(filter['kind'].to_s) ||
      filter['role'].to_s == 'dimension'
  end

  # Does a Sigma controlType source a STRING value-list (→ decode required)?
  def decode_control_type?(control_type)
    DECODE_CONTROL_TYPES.include?(control_type.to_s)
  end

  # Is a column formula already a Text()-decode of a single reference?
  # Matches `Text([X/Y])` / `Text([Y])` (the shape the routing emits and the
  # lint checks); deliberately does NOT match `ToText(` (not a Sigma function).
  DECODE_FORMULA_RE = /\AText\s*\(\s*\[[^\]]+\]\s*\)\s*\z/i
  def decode_formula?(formula)
    formula.to_s.strip =~ DECODE_FORMULA_RE ? true : false
  end

  # The decode helper column for a raw column reference. `ref` is the Sigma
  # reference to the raw integer column as written on the TARGET element, e.g.
  # "[Master/Order Store Key]" (base table) or "[Order Store Key]" (sibling on
  # the master). Text() is the correct Sigma string cast (ToText() does not
  # exist — column-gotchas.md).
  def decode_formula_for(ref)
    "Text(#{ref})"
  end

  # Human-facing decode-helper column name: "<Name> (Text)" — Twin C's exact
  # by-hand naming (skt-el-balance-vs-growth "Order Store Key (Text)").
  def decode_name(name)
    "#{name} (Text)"
  end

  # A deterministic decode-column id for a base name + owning element id, so a
  # re-run is stable and two controls on the same element don't collide.
  def decode_col_id(base_slug, owner_id)
    "skt-#{base_slug}-#{owner_id}".gsub(/[^A-Za-z0-9_-]+/, '-').gsub(/-+/, '-').sub(/-\z/, '')
  end
end
