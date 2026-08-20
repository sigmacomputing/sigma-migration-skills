# frozen_string_literal: true
# table_map.rb — repoint a converted DM's warehouse-table sources onto the tables
# the data was actually landed in. Powers `convert-model.rb --table-map` and the
# non-warehouse-source handoff (Fabric Dataflow / Lakehouse / OneLake / Dataverse
# / file → powerbi-import-to-snowflake lands the data → repoint here).
#
# Accepts EITHER a plain {model_table => warehouse_table} map OR the
# powerbi-import-to-snowflake manifest.json ({tables:[{pbi_table, sf_table}]})
# directly, so the land-then-repoint handoff is one step with no manual map.
#
# Pure + offline (no API, no creds) → unit-tested in test-table-map-manifest.rb.
require 'json'

module TableMap
  # Read a --table-map file. Returns { tmap: {name=>landed}, from_manifest: bool }.
  # A manifest's landed value is the fully-qualified DB.SCHEMA.TABLE (sf_table);
  # a plain-map value is a bare table name.
  def self.load(path)
    raw = JSON.parse(File.read(path))
    from_manifest = raw.is_a?(Hash) && raw['tables'].is_a?(Array) &&
                    !raw['tables'].empty? &&
                    raw['tables'].all? { |t| t.is_a?(Hash) && t['pbi_table'] && t['sf_table'] }
    tmap = if from_manifest
             raw['tables'].each_with_object({}) { |t, h| h[t['pbi_table'].to_s] = t['sf_table'].to_s }
           else
             raw
           end
    { tmap: tmap, from_manifest: from_manifest }
  end

  # Repoint warehouse-table elements in `dm` per `tmap` (mutates dm). Model table
  # is matched to an element by normalizing away case + non-alphanumerics, so a
  # manifest keyed by the PBI table NAME ("SalesFlow") matches the element's
  # physical-name path tail ("SALES_FLOW"). A dotted value repoints the WHOLE path
  # (db.schema.table); a bare value swaps only the tail. Base column formulas
  # [OLD_TAIL/Col] → [NEW_TAIL/Col] are rewritten in lockstep (raw warehouse-column
  # refs are TABLE-TAIL-prefixed, so a path change without this fails the POST with
  # "dependency not found"). Element NAMES stay untouched (derived "View" elements
  # reference base elements BY NAME). Returns the array of applied remaps.
  def self.apply!(dm, tmap)
    norm = ->(s) { s.to_s.upcase.gsub(/[^A-Z0-9]/, '') }
    applied = []
    (dm['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        src = el['source'] || {}
        next unless src['kind'] == 'warehouse-table' && src['path'].is_a?(Array) && !src['path'].empty?
        tail = src['path'][-1].to_s
        hit = tmap.find { |k, _| norm.call(k) == norm.call(tail) }
        next unless hit
        landed = hit[1].to_s
        parts = landed.include?('.') ? landed.split('.') : nil
        new_tail = parts ? parts[-1] : landed
        # A plain-map entry mapping a tail to itself is a no-op; a dotted manifest
        # value always applies (it also repoints db/schema).
        next if !parts && new_tail.upcase == tail.upcase
        src['path'] = parts ? parts.map(&:upcase) : (src['path'][0..-2] + [landed])
        (el['columns'] || []).each do |c|
          f = c['formula']
          c['formula'] = f.sub("[#{tail}/", "[#{new_tail}/") if f.is_a?(String) && f.start_with?("[#{tail}/")
        end
        applied << { 'tail' => tail, 'path' => src['path'] }
      end
    end
    applied
  end
end
