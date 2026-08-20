# frozen_string_literal: true

# Pure logic: which dataset-map.json entries need landing, and how to patch
# one in place once landed. Mirrors build-dm.rb's own
# derive_map_entry/autofill_dataset_map split (pure logic, thin filesystem
# seam elsewhere) so this stays offline-testable.
module LandingManifest
  SENTINEL_SOURCE = 'domo-landed-data'
  LANDED_SOURCE   = 'domo-landed-snowflake'

  module_function

  # ds_map: the parsed dataset-map.json Hash (id -> entry). dataset_ids: an
  # optional explicit subset (CLI --dataset-id); nil/empty means "every
  # SENTINEL_SOURCE entry".
  def ids_to_land(ds_map, dataset_ids: nil)
    if dataset_ids && !dataset_ids.empty?
      dataset_ids
    else
      ds_map.select { |_id, entry| entry['_source'] == SENTINEL_SOURCE }.keys
    end
  end

  # Build the patched entry for a dataset that just landed successfully.
  # Never touches connectionId — same rule build-dm.rb's autofill_dataset_map
  # enforces (it's a Sigma-side id with no Domo analog, always human-supplied).
  def patched_entry(existing_entry, database:, schema:, table:)
    entry = (existing_entry || {}).dup
    entry['database'] = database
    entry['schema']   = schema
    entry['table']    = table
    entry['_source']  = LANDED_SOURCE
    entry.delete('_note')
    entry['connectionId'] ||= ''
    entry
  end
end
