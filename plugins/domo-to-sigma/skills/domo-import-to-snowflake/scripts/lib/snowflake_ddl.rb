# frozen_string_literal: true

# Pure logic: Domo schema.columns[] -> Snowflake typed DDL. No network, no
# filesystem — matches column_preflight.rb's own pure/offline-testable style.
module SnowflakeDDL
  # Domo's query_dataset metadata[].type enum -> a Snowflake column type.
  # schema_cols (this module's input everywhere) is built by
  # DomoExtract.extract_rows from the FIRST extraction page's `columns` +
  # `metadata[].type`, NOT from Domo.dataset(id)['schema']['columns'] — live
  # validation found that field empty for 9 of 10 real sample DataSets, so
  # this skill never reads it for typing (see refs/live-validation.md).
  # STRING/LONG/DATETIME were confirmed live; DECIMAL/DOUBLE/DATE below are
  # inferred from Domo's documented type enum, not independently confirmed.
  # An unrecognized type falls back to VARCHAR rather than raising — see
  # unknown_types for the audit trail — so one odd column never blocks
  # landing a whole DataSet.
  DOMO_TO_SNOWFLAKE = {
    'STRING'   => 'VARCHAR',
    'LONG'     => 'NUMBER(38,0)',
    'DECIMAL'  => 'FLOAT',
    'DOUBLE'   => 'FLOAT',
    'DATE'     => 'DATE',
    'DATETIME' => 'TIMESTAMP_NTZ'
  }.freeze

  module_function

  def column_type(domo_type)
    DOMO_TO_SNOWFLAKE.fetch(domo_type.to_s.upcase, 'VARCHAR')
  end

  # Domo type strings not in DOMO_TO_SNOWFLAKE, deduped, for a caller to warn
  # on (never a hard failure — see column_type).
  def unknown_types(schema_cols)
    Array(schema_cols)
      .map { |c| c['type'].to_s.upcase }
      .reject { |t| DOMO_TO_SNOWFLAKE.key?(t) }
      .uniq
  end

  # ALWAYS double-quote, so the identifier lands with the source's exact case.
  # Snowflake case-folds an UNQUOTED identifier to upper case; that silently
  # destroys the camelCase word boundary domo-to-sigma's DomoSigma.display_name
  # splits on downstream ('IsClosed' -> 'Is Closed', but 'ISCLOSED' -> the
  # single token 'ISCLOSED'), so a landed column stops matching the Domo-declared
  # one and column_preflight.rb reports it missing. Quoting only the names that
  # strictly require it — the previous behavior — meant multi-word camelCase
  # columns broke while single-word and symbol-bearing ones happened to survive.
  # Found live by the 48-card cold run against the real PDP DataSet (bead q5dz).
  def quote_identifier(name)
    "\"#{name.to_s.gsub('"', '""')}\""
  end

  # database/schema/table: plain strings already chosen by the caller
  # (CLI --target-db/--target-schema, or a table name derived from the
  # DataSet) — this function only emits SQL, it doesn't decide naming.
  def create_table_sql(database, schema, table, schema_cols)
    cols = Array(schema_cols).map { |c|
      "  #{quote_identifier(c['name'])} #{column_type(c['type'])}"
    }.join(",\n")
    "CREATE TABLE IF NOT EXISTS #{database}.#{schema}.#{quote_identifier(table)} (\n#{cols}\n);"
  end
end
