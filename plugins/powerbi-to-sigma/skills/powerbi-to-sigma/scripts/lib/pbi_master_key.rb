# frozen_string_literal: true
#
# PbiMasterKey — key a workbook master on the PBI TABLE identity, not the warehouse
# table, so ROLE-PLAYING DIMENSION copies stay distinct.
#
# THE BUG (measured on real customer report R2, 2026-07-30). The model imports the SAME
# warehouse table six times under different names to get six role-playing date
# dimensions (`DATE_DIM Policy Count`, `… Quoted date`, `… prod trans date`,
# `… submission date`, `… submission eff date`, `… uw quotes`), each a different column
# subset. The converter names every emitted element after the WAREHOUSE table, so all
# six arrive named `DATE_DIM`. migrate-powerbi.rb then keyed masters on that name:
#
#     mkey = cname                        # "DATE_DIM" for all six
#     mid  = "master-#{SHA1(cname)[0,8]}" # one id for all six
#     masters[mkey] = { ... }             # OVERWRITES — last copy wins
#     field_map["#{cname}.#{col}"] = ...  # "DATE_DIM.CALENDAR_DATE"
#
# Six masters collapsed into one (only the last copy's columns survived), while the
# report's visuals bind under the PBI name — `DATE_DIM submission date.CALENDAR_DATE`,
# a key that never existed. The `physical_to_pbi` alias patch was a 1:1 Hash over a 1:N
# problem, so five of the six copies got no alias at all. Result: dropped columns, and
# controls silently targeting the WRONG date dimension.
#
# HOW ELEMENTS ARE MATCHED BACK TO TABLES. The converter emits one element per model
# table in table order, so POSITION is a good primary signal — but relying on it alone
# is fragile (calculated tables become Custom SQL elements, joined "View" elements are
# appended, and any future reordering would silently mis-key every copy). Verified on
# R2: column NAME SETS are unique across the six copies (6 of 6) while column COUNTS are
# not (only 3 distinct). So the column set is the authoritative signal and position is
# only a tie-break. An element nothing explains returns nil — the caller then falls back
# to the element name, which is the old behaviour, so an unmatched element can never be
# mis-attributed to some other table.
require 'digest'
require 'set'

module PbiMasterKey
  module_function

  # A column formula "[DATE_DIM/Calendar Date]" or "[FACT/DIM/Col]" -> its leaf,
  # normalized for comparison against a TMSL column name ("CALENDAR_DATE").
  def norm_col(s)
    leaf = s.to_s.gsub(/\A\[|\]\z/, '').split('/').last.to_s
    leaf = leaf.sub(/\s+\([^)]*\)\s*\z/, '')   # drop Sigma's " (RelName)" disambiguator
    leaf.downcase.gsub(/[^a-z0-9]/, '')
  end

  def norm_table(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # The warehouse table a TMSL table's Power Query M points at (the path tail), or nil.
  def physical_tail(table)
    e = ((table['partitions'] || [])[0] || {}).dig('source', 'expression')
    e = e.join("\n") if e.is_a?(Array)
    e.to_s[/\[\s*Name\s*=\s*"([^"]+)"\s*,\s*Kind\s*=\s*"(?:Table|View)"\s*\]/i, 1]
  end

  # normalized physical table -> [PBI table name, ...]   (1:N — the whole point)
  def physical_to_pbi(tables)
    out = {}
    (tables || []).each do |t|
      tail = physical_tail(t)
      next if tail.nil? || t['name'].to_s.empty?
      (out[norm_table(tail)] ||= []) << t['name']
    end
    out
  end

  # element index -> { table:, confidence: } (table nil when nothing explains it).
  #
  # ORDER IS AUTHORITATIVE. The converter emits one element per model table in table
  # order, so the k-th emitted element whose warehouse path tail is X corresponds to the
  # k-th model table that sources X. Measured on 4 real models: this assigns 20/21,
  # 26/28, 11/11 and 13/13 base elements, and on the 6-copy DATE_DIM model it recovers
  # all six copies BY NAME.
  #
  # A first attempt made the COLUMN SET authoritative (require the table to cover the
  # element's columns) and it was WORSE THAN THE OLD BEHAVIOUR on real data — distinct
  # masters fell 18->12 and 21->14, because the converter adds columns the TMSL table
  # does not have (time-intel, window helpers), so "cover" failed and the element went
  # unresolved. The column set is still valuable, but as a CONFIDENCE signal: the caller
  # can warn when the k-th table does not look like the k-th element. Measured agreement
  # at a 0.8 overlap threshold: 18/20, 25/26, 11/11, 13/13.
  def pbi_table_for_elements(elements, tables)
    by_tail = {}
    (tables || []).each do |t|
      tl = physical_tail(t)
      next unless tl
      (by_tail[norm_table(tl)] ||= []) << t
    end
    seen = Hash.new(0)
    out = {}
    (elements || []).each_with_index do |el, idx|
      path = el.dig('source', 'path')
      tl = norm_table(path.is_a?(Array) && !path.empty? ? path[-1] : el['name'])
      list = by_tail[tl] || []
      k = seen[tl]
      seen[tl] += 1
      if k >= list.size
        out[idx] = { 'table' => nil, 'confidence' => 0.0 }
        next
      end
      t = list[k]
      out[idx] = { 'table' => t['name'], 'confidence' => column_overlap(el, t) }
    end
    out
  end

  # Fraction of the element's columns the table explains (0.0..1.0). A LOW value means
  # the order-based assignment disagrees with the column evidence — worth warning about,
  # not worth overriding, since the converter legitimately adds columns.
  def column_overlap(element, table)
    elc = (element['columns'] || []).map { |c| norm_col(c['formula'] || c['name']) }.to_set
    return 0.0 if elc.empty?
    tc = (table['columns'] || []).map { |c| norm_col(c['name']) }.to_set
    ((elc & tc).size.to_f / elc.size).round(3)
  end

  # Convenience: index -> table name only.
  def table_names(elements, tables)
    pbi_table_for_elements(elements, tables).transform_values { |v| v['table'] }
  end

  # The master key IS the PBI table name — that is the identity the report's queryRefs
  # use. Kept as a function so the intent is explicit at the call site.
  def master_key(pbi_table_name)
    pbi_table_name.to_s
  end

  def master_id(key)
    "master-#{Digest::SHA1.hexdigest(key.to_s)[0, 8]}"
  end
end
