# frozen_string_literal: true

require_relative 'relationship_route'

# Whether an explicit reused data model satisfies the embedded-extract landing
# gate (exit 17). Landing exists so a FRESH converter model has warehouse
# tables to read. A model reused by explicit --reuse-dm <id> that this workdir
# did not post (the reused-DM evidence route, RelationshipRoute.eligible?)
# already names its own warehouse tables, so landed copies would never be read
# and the gate is satisfied without the --skip-extract-landing escape.
# --db/--schema (or --table-mapping) stay required: parity and the relationship
# map resolve the warehouse tables through them.
module ExtractLandingRoute
  WAREHOUSE_NAMED = '--db/--schema (or --table-mapping) naming the warehouse tables the reused model reads'

  module_function

  # { satisfied:, blocker: } — blocker names what keeps an otherwise eligible
  # reuse from satisfying the gate; nil when reuse is not in play at all.
  def reuse(workdir:, reuse_dm:, db:, schema:, table_mapping:)
    return { satisfied: false, blocker: nil } unless RelationshipRoute.eligible?(workdir: workdir, reuse_dm: reuse_dm)
    named = (present?(db) && present?(schema)) || (table_mapping.is_a?(Hash) && table_mapping.any?)
    named ? { satisfied: true, blocker: nil } : { satisfied: false, blocker: WAREHOUSE_NAMED }
  end

  # Once the reuse decision is final. A reuse candidate can still be refused
  # after the gate (missing required fields), and then a fresh converter model
  # over the unlanded extract would ship — the landing stop fires instead.
  def stop_after_settle?(satisfied_by_reuse:, reused:)
    satisfied_by_reuse ? !reused : false
  end

  def present?(value)
    !value.to_s.strip.empty?
  end
end
