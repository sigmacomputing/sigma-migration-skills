# frozen_string_literal: true
#
# PbiViewRoute — master-map passes that let a CROSS-TABLE visual resolve on the
# converter's joined "<FACT> View" element. Extracted from migrate-powerbi.rb so the
# passes can be tested offline (scripts/test-cross-table-view-route.rb).
require_relative 'pbi_field_alts'

module PbiViewRoute
  module_function

  def norm(s)
    s.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  # PBI-friendly-entity aliases ([bead]): a key "VW_SALES.Amount" is
  # ALSO reachable as "Sales.Amount" — the form PBIR visuals actually use. The DM
  # element is named after the physical view ("vw_sales") but the visual binds under
  # the friendly entity, and field_spec's normalize-fallback can't bridge a `vw_`
  # prefix. Never overwrites an existing key; only adds when the physical element maps
  # to a DIFFERENT friendly name. Returns the number of aliases added.
  def add_friendly_aliases!(field_map, physical_to_pbi)
    return 0 if physical_to_pbi.nil? || physical_to_pbi.empty?

    aliases = {}
    field_map.each do |k, v|
      ent, dot, leaf = k.rpartition('.')
      next if dot.empty? || ent.empty? || leaf.empty?

      pbis = Array(physical_to_pbi[norm(ent)])
      # With N>1 copies the physical name is AMBIGUOUS — aliasing it to one of them is
      # how a control ended up filtering the wrong date dimension. Alias only the
      # unambiguous 1:1 case; the N-copy case is already keyed under each PBI table.
      next unless pbis.size == 1

      pbi = pbis.first
      next unless pbi && norm(pbi) != norm(ent)

      ak = "#{pbi}.#{leaf}"
      aliases[ak] = v unless field_map.key?(ak) || aliases.key?(ak)
    end
    field_map.merge!(aliases)
    aliases.size
  end

  # Bug A (star schema): a cross-table visual binds a DIMENSION from a dim table
  # (e.g. PRODUCT_DIM.Category) AND a MEASURE from the fact (ORDER_FACT.Net Rev).
  # Those route to DIFFERENT per-table masters, but a Sigma chart element can only
  # reference columns from its OWN source master — a cross-master ref error-types.
  # The converter already builds a denormalized "<Fact> View" element that carries
  # the fact columns + every related dim column (disambiguated "Leaf (DIM)"). So
  # register an ALT on the View for every field the View also exposes, leaving the
  # visual with a single coherent source.
  #
  # Registered as an ALT, not the primary (grain fix, found live during the
  # control-targeting wave): making the View the PRIMARY routed EVERY field of the
  # subsumed tables onto the join element, so a SINGLE-table visual (e.g. Median
  # Salary over EMPLOYEES) silently evaluated at the JOIN grain and diverged (live:
  # Sigma median 73,500 vs PBI 73,000). As an alt, visual_master still majority-picks
  # the View for CROSS-table visuals while same-table visuals tie-break to the
  # field's own master and keep their source grain.
  # FRIENDLY vs PHYSICAL names (found live on a Fabric-published model). Masters are
  # keyed on the Power BI table name ("PointOfSale", "Product"), but the converter
  # names elements — and so the View ("F_POINT_OF_SALE View") and its disambiguated
  # dim columns ("Category (D_PRODUCT)") — after the WAREHOUSE table. Comparing the two
  # spellings directly matched nothing, so no field got a View alt and every
  # cross-table visual lost its measure. A master therefore answers to its PBI name AND
  # its physical table name — the latter only when that warehouse table backs exactly
  # ONE PBI table (a role-playing copy is ambiguous and must not borrow another copy's
  # View column).
  def entity_spellings(master_key, tables)
    out = [master_key.to_s]
    t = (tables || []).find { |tb| tb['name'].to_s == master_key.to_s }
    tail = t && PbiMasterKey.physical_tail(t)
    if tail
      copies = (tables || []).count { |tb| norm(PbiMasterKey.physical_tail(tb)) == norm(tail) }
      out << tail if copies == 1
    end
    # Dedupe on the exact (case-insensitive) spelling, NOT norm(): "DimDate" and "DIM_DATE"
    # normalize equal but are different strings, and the View's "(DIM_DATE)" suffix is only
    # matched by the physical spelling (PbiMasterKey.view_column compares with casecmp).
    out.uniq(&:downcase)
  end

  def add_view_alts!(field_map, masters, conv_elements, tables)
    spellings_for = Hash.new { |h, k| h[k] = entity_spellings(k, tables) }
    conv_elements.each do |vcel|
      vname = vcel['name'].to_s
      next unless vname =~ /\sView$/ # the denormalized join element
      next unless masters[vname]

      vmid  = masters[vname]['id']
      vcols = masters[vname]['columns'] || []
      # leaf -> View column name (prefer the bare-leaf col when present, else the
      # first disambiguated "Leaf (DIM)" col).
      leaf_to_view = {}
      vcols.each do |c|
        leaf = c['name'].to_s.sub(/\s+\([^)]*\)\s*$/, '') # strip " (DIM)" suffix
        leaf_to_view[leaf] ||= c['name']
        leaf_to_view[c['name']] ||= c['name'] # exact disambiguated form too
      end
      # the fact this View denormalizes (drop the trailing " View").
      fact = vname.sub(/\s+View$/, '')
      # masters whose columns the View subsumes: the fact + every dim reachable via
      # a "(DIM)" suffix in the View's columns.
      subsumed = [fact] + vcols.map { |c| c['name'][/\(([^)]*)\)\s*$/, 1] }.compact.uniq
      subsumed = subsumed.map { |n| norm(n) }
      field_map.each do |qr, fs|
        next unless spellings_for[fs['master'].to_s].any? { |n| subsumed.include?(norm(n)) }
        next if fs['master'] == vname

        old_mid = masters[fs['master']] ? masters[fs['master']]['id'] : nil
        ref_str = fs['ref'].to_s
        is_plain_col = ref_str =~ /\A\[[^\]]+\]\z/ # exactly one bracketed ref, no agg
        add_alt = lambda do |ref|
          alts = (fs['alts'] ||= [])
          alts << { 'master' => vname, 'ref' => ref, 'agg' => fs['agg'] } unless
            alts.any? { |a| a['master'] == vname }
        end
        if is_plain_col
          # plain dimension/column ref: match its leaf to a View column.
          # Prefer the entity-qualified dimension; a same-named fact column or
          # inactive role-playing dimension is not interchangeable. Try the PBI name,
          # then the physical name the View's "(DIM)" suffixes actually use.
          spellings = spellings_for[fs['master'].to_s]
          # G28: strip ONLY an entity-disambiguation suffix off the field. A field whose
          # own name carries a parenthetical ("DimDate.Date (Fiscal Month)") keeps it, so it
          # routes to "Date (Fiscal Month) (DimDate)" and not the plain "Date (DimDate)" (which
          # plotted every monthly chart daily).
          leaf = PbiFieldAlts.view_lookup_leaf(qr, spellings + [fs['master'].to_s])
          is_fact = spellings.any? { |n| norm(n) == norm(fact) }
          vcol = nil
          spellings.each { |n| vcol ||= PbiMasterKey.view_column(vcols, n, leaf, is_fact ? n : fact) }
          next unless vcol

          add_alt.call("[#{vmid}/#{vcol}]")
        elsif old_mid
          # measure/aggregation formula: every referenced fact column must exist on
          # the View (it does — the View carries all fact columns). Swap the old
          # master id for the View master id and remap each inner column leaf.
          remapped = ref_str.gsub(/\[#{Regexp.escape(old_mid)}\/([^\]]+)\]/) do
            inner = Regexp.last_match(1)
            mapped = leaf_to_view[inner] || leaf_to_view[inner.sub(/\s+\([^)]*\)\s*$/, '')] || inner
            "[#{vmid}/#{mapped}]"
          end
          # only register if we actually rewrote a ref onto the View master.
          add_alt.call(remapped) if remapped.include?(vmid)
        end
      end
    end
  end
end
