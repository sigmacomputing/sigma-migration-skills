# frozen_string_literal: true
#
# equivalence_probe.rb — build + judge the SEMANTIC-EDIT EQUIVALENCE LEDGER
# (<workdir>/semantic-edits.json): the "provably no-op must be PROVEN" contract
# (PLAN-v3 PR-8).
#
# WHY: in a field migration an agent deleted a LEFT JOIN as "provably no-op"
# with zero verification. The key was a non-unique flag column, so eliding (or
# keeping) the join changes row counts — fan-out either way, silently wrong
# aggregates everywhere downstream. Corpus twin:
# corpus/tableau/join-elision-fanout (LEFT JOIN on a non-unique flag key, no
# joined column on any shelf — the join "looks removable"; it is not provably
# removable without measurement).
#
# CONTRACT: any structural edit to source semantics — dropping a join,
# collapsing a table, rewriting a filter — is FORBIDDEN without a recorded
# equivalence proof: three probes measured on BOTH sides through the same
# warehouse seam every other probe uses (scripts/probe-equivalence.rb):
#   COUNT(*)                     row-count checksum (catches fan-out/loss)
#   COUNT(DISTINCT <grain>)      declared-grain cardinality (catches dup keys)
#   SUM(<measure>) per measure   numeric checksums (catches value drift)
# assert-phase6-ran.rb gate 20 (exit 27) refuses GREEN while any declared
# entry lacks a proof block or its proof says match:false. A REFUTED edit that
# was consequently NOT applied is withdrawn (probe-equivalence.rb --withdraw):
# the entry moves to the ledger's `withdrawn` array with its refuted proof
# preserved verbatim as evidence — gate 20 ignores withdrawn entries but
# reports them informationally. Never hand-edit the ledger.
#
# HONESTY NOTE (read before trusting the gate): nothing mechanical can detect
# an edit nobody DECLARED — this ledger + gate police declared edits only. The
# operating-contract rule (refs/operating-contract.md) makes the declaration
# mandatory, and the join-plan (gate 16) + ground-truth (gate 18) oracles are
# the mechanical net for undeclared ones: ground-truth SQL is derived from the
# .twb signals independently of the built spec, so a silently dropped join
# shifts the built numbers away from the derived truth and gate 18 diverges.
#
# Ruby 2.6-compatible. Offline judging (no network); execution lives in
# scripts/probe-equivalence.rb.

require 'json'

module EquivalenceProbe
  NOTE = 'Structural edits to source semantics (join drop / table collapse / filter rewrite) ship ' \
         'only with a recorded equivalence proof: COUNT(*), COUNT(DISTINCT grain) and per-measure ' \
         'SUM checksums measured on BOTH sides. "Provably no-op" is proven by probe-equivalence.rb, ' \
         'never asserted; an entry without a proof block (or with match:false) blocks GREEN ' \
         '(gate 20, exit 27). Only DECLARED edits are policeable here — the operating contract ' \
         'forbids undeclared ones, and gates 16/18 catch the drift they cause.'

  # Relative tolerance for SUM checksum comparison — float-noise only, never a
  # drift allowance (a real difference is orders of magnitude above this).
  REL_TOL = 1e-9

  module_function

  # ---- SQL builders ---------------------------------------------------------

  # Distinct-grain expression (same folding probe-join-keys.rb totals_sql
  # uses — do not diverge): a single-column grain counts the column directly;
  # a composite grain concats COALESCE(TO_VARCHAR(col), '') with '|'.
  def grain_expr(grain)
    return grain.first if grain.size == 1
    grain.map { |k| "COALESCE(TO_VARCHAR(#{k}), '')" }.join(" || '|' || ")
  end

  def sum_alias(measure)
    "SUM_#{measure.to_s.gsub(/[^A-Za-z0-9]+/, '_').upcase}"
  end

  # ONE statement per side — counts, grain cardinality and every SUM checksum
  # in a single scan, the side's whole statement wrapped as a subquery (the
  # probe never edits the statement it is judging).
  def probe_sql(sql, grain, measures)
    cols = ['COUNT(*) AS TOTAL_ROWS', "COUNT(DISTINCT #{grain_expr(grain)}) AS DISTINCT_GRAIN"]
    Array(measures).each { |m| cols << "SUM(#{m}) AS #{sum_alias(m)}" }
    "SELECT #{cols.join(', ')} FROM (\n#{sql}\n) EQ_PROBE"
  end

  def probe_columns(measures)
    %w[TOTAL_ROWS DISTINCT_GRAIN] + Array(measures).map { |m| sum_alias(m) }
  end

  # ---- DM element extraction ------------------------------------------------

  def find_element(dm_spec, name)
    return nil unless dm_spec.is_a?(Hash)
    (dm_spec['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        return el if (el['name'] || el['id']).to_s == name.to_s
      end
    end
    nil
  end

  # The element's own SQL: a Custom SQL statement verbatim, or SELECT * over
  # the physical table path. nil when neither exists (the caller errors loud).
  def element_sql(el)
    src = el.is_a?(Hash) ? el['source'] : nil
    return nil unless src.is_a?(Hash)
    if src['kind'] == 'sql'
      stmt = src['statement'].to_s
      stmt.strip.empty? ? nil : stmt
    elsif src['path'].is_a?(Array) && !src['path'].empty?
      "SELECT * FROM #{src['path'].join('.')}"
    end
  end

  # Numeric measures derivable from an element spec: every column whose
  # formula is an additive Sum over a single bracket ref (Sum([X])) yields X's
  # physical name. --measures overrides / supplements when the spec carries
  # none — never guess beyond this shape.
  def element_measures(el)
    out = []
    Array(el.is_a?(Hash) ? el['columns'] : nil).each do |c|
      next unless c.is_a?(Hash)
      m = c['formula'].to_s.match(/\A\s*Sum\(\s*\[([^\]]+)\]\s*\)\s*\z/i)
      next unless m
      phys = physical_name(m[1].split('/').last)
      out << phys unless out.include?(phys)
    end
    out
  end

  # Display -> physical, the converter's convention ('Entity Id' -> ENTITY_ID;
  # same folding as JoinPlan.physical_name — do not diverge).
  def physical_name(display)
    display.to_s.strip.gsub(/\s+/, '_').upcase
  end

  # ---- result shaping + comparison ------------------------------------------

  # Normalize one side's raw result ({'total'=>N, 'distinct'=>M,
  # 'sums'=>{measure-or-SUM_alias => v}}) into the recorded proof shape
  # {'total'=>Integer, 'distinct_grain'=>Integer, 'sums'=>{measure=>Float|nil}}.
  # A nil sum is a real observation (SUM over zero rows) and compares as nil.
  def side_metrics(raw, measures)
    raw_sums = raw['sums'].is_a?(Hash) ? raw['sums'] : {}
    sums = {}
    Array(measures).each do |m|
      v = raw_sums.key?(m) ? raw_sums[m] : raw_sums[sum_alias(m)]
      sums[m] = num_or_nil(v)
    end
    { 'total'          => raw['total'].nil? ? nil : raw['total'].to_i,
      'distinct_grain' => raw['distinct'].nil? ? nil : raw['distinct'].to_i,
      'sums'           => sums }
  end

  def num_or_nil(v)
    return nil if v.nil? || v.to_s.strip.empty?
    Float(v)
  rescue ArgumentError, TypeError
    nil
  end

  def nearly_equal(a, b)
    return true if a.nil? && b.nil?
    return false if a.nil? || b.nil?
    return true if a == b
    (a - b).abs <= [a.abs, b.abs].max * REL_TOL
  end

  # [{'metric','before','after'}, ...] — empty means the two sides agree on
  # every probe (row count, grain cardinality, every SUM checksum).
  def mismatches(before, after)
    out = []
    unless before['total'] == after['total']
      out << { 'metric' => 'TOTAL_ROWS', 'before' => before['total'], 'after' => after['total'] }
    end
    unless before['distinct_grain'] == after['distinct_grain']
      out << { 'metric' => 'DISTINCT_GRAIN', 'before' => before['distinct_grain'], 'after' => after['distinct_grain'] }
    end
    (before['sums'].keys | after['sums'].keys).each do |m|
      b = before['sums'][m]
      a = after['sums'][m]
      out << { 'metric' => sum_alias(m), 'before' => b, 'after' => a } unless nearly_equal(b, a)
    end
    out
  end

  # ---- ledger ---------------------------------------------------------------

  def load(path)
    return { 'entries' => [] } unless File.exist?(path)
    doc = JSON.parse(File.read(path))
    doc = { 'entries' => doc } if doc.is_a?(Array)
    doc = { 'entries' => [] } unless doc.is_a?(Hash)
    doc['entries'] = [] unless doc['entries'].is_a?(Array)
    doc
  end

  # Rewrite the ledger. Accepts either the whole doc Hash (round-trip: every
  # top-level key an operator or a future version added — e.g. a
  # withdrawal_note — is preserved verbatim) or, back-compat, a bare entries
  # Array. generated_at/note are always restamped; nothing else is dropped.
  def write(path, entries_or_doc)
    doc = entries_or_doc.is_a?(Hash) ? entries_or_doc : { 'entries' => entries_or_doc }
    out = { 'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
            'note'         => NOTE,
            'entries'      => doc['entries'] || [] }
    doc.each { |k, v| out[k] = v unless out.key?(k) }
    File.write(path, JSON.pretty_generate(out))
    path
  end

  # Re-probing the same edit_description REPLACES its entry — a proof binds to
  # the exact before/after pair it measured; stale proofs never accumulate.
  def upsert(entries, entry)
    i = entries.index { |e| e.is_a?(Hash) && e['edit_description'].to_s == entry['edit_description'].to_s }
    i ? entries[i] = entry : entries << entry
    entries
  end

  def proven?(entry)
    entry.is_a?(Hash) && entry['proof'].is_a?(Hash) && entry['proof']['match'] == true
  end

  def refuted?(entry)
    entry.is_a?(Hash) && entry['proof'].is_a?(Hash) && entry['proof']['match'] == false
  end

  # Withdraw a REFUTED-and-NOT-APPLIED edit: move its entry (verbatim — the
  # refuted proof stays as evidence) from entries to the doc's `withdrawn`
  # array, stamped with the operator's reason + withdrawn_at. Only a refuted
  # entry is withdrawable: a proven one doesn't block (nothing to withdraw),
  # and an unproven one was never measured — re-probe first, never withdraw an
  # unmeasured claim. Returns [:ok, moved_entry] | [:not_found, nil] |
  # [:proven, entry] | [:unproven, entry].
  # HONESTY NOTE: withdrawal ATTESTS the refuted edit was not applied — whether
  # its SQL nonetheless shipped is not detectable mechanically; gates 16/18
  # remain the numeric net for an edit that rode along anyway.
  def withdraw(doc, edit_description, reason, at = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'))
    entries = doc['entries']
    i = entries.index { |e| e.is_a?(Hash) && e['edit_description'].to_s == edit_description.to_s }
    return [:not_found, nil] unless i
    entry = entries[i]
    return [:proven, entry] if proven?(entry)
    return [:unproven, entry] unless refuted?(entry)
    entries.delete_at(i)
    moved = entry.merge('withdrawn_reason' => reason, 'withdrawn_at' => at)
    doc['withdrawn'] = [] unless doc['withdrawn'].is_a?(Array)
    doc['withdrawn'] << moved
    [:ok, moved]
  end
end
