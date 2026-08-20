# frozen_string_literal: true

require 'open3'
require 'csv'
require 'json'
require 'tmpdir'
require_relative 'snowflake_ddl'

# Typed DDL + snow CLI PUT/COPY INTO, mirroring
# powerbi-import-to-snowflake's load step (same subprocess-CLI pattern, Ruby
# instead of Python). Command-building is pure and unit-tested; actually
# running the command against real Snowflake is the thin, untested-offline
# half — proven by live validation (this plan's Task 7), not a unit test.
module SnowflakeLoad
  class CommandFailed < StandardError; end

  module_function

  # rows: array of arrays (DomoExtract's shape). Quotes every field per
  # RFC4180 (Ruby's CSV library) so a raw value containing a comma/quote/
  # newline can't corrupt the column count COPY INTO relies on.
  def rows_to_csv(rows)
    CSV.generate { |csv| rows.each { |row| csv << row } }
  end

  # The `snow sql` invocation that creates the table, PUTs a local CSV file
  # to Snowflake's table stage, and COPYs it in — one statement per
  # semicolon so `snow sql -f` runs them as a single multi-statement session.
  def load_sql(create_table_sql, database, schema, table, file_uri)
    quoted = SnowflakeDDL.quote_identifier(table)
    <<~SQL
      #{create_table_sql}
      PUT '#{file_uri}' @#{database}.#{schema}.%#{quoted} AUTO_COMPRESS=TRUE OVERWRITE=TRUE;
      COPY INTO #{database}.#{schema}.#{quoted}
        FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 0 NULL_IF = (''))
        ON_ERROR = ABORT_STATEMENT;
    SQL
  end

  def grant_sql(database, schema, table, role)
    "GRANT SELECT ON #{database}.#{schema}.#{SnowflakeDDL.quote_identifier(table)} TO ROLE #{role};"
  end

  def count_sql(database, schema, table)
    "SELECT COUNT(*) AS CNT FROM #{database}.#{schema}.#{SnowflakeDDL.quote_identifier(table)};"
  end

  # Measured (not assumed) row-count parity check on the Snowflake side,
  # mirroring DomoExtract's own extract_with_parity pattern. run_sql!'s zero
  # exit code only proves the COPY command didn't error — it's not proof the
  # table actually holds the rows that were supposed to land (a re-run
  # against an already-landed table after an interrupted batch could
  # silently duplicate rows if Snowflake's COPY load-history dedup doesn't
  # recognize a re-staged file as identical). Uses `--format JSON`
  # (CONFIRMED live to return `[{"CNT": <n>}]`) rather than parsing the
  # default ASCII-table output.
  def verify_landed_count!(database, schema, table, expected_count, connection:, runner: method(:system_run))
    sql = count_sql(database, schema, table)
    out = run_sql!(sql, connection: connection, runner: runner, format_json: true)
    parsed = begin
      JSON.parse(out)
    rescue JSON::ParserError => e
      raise CommandFailed, "verify_landed_count! for #{database}.#{schema}.#{table}: " \
        "could not parse snow sql --format JSON output as JSON (#{e.message}):\n#{out}"
    end
    unless parsed.is_a?(Array) && parsed[0].is_a?(Hash) && parsed[0].key?('CNT')
      raise CommandFailed, "verify_landed_count! for #{database}.#{schema}.#{table}: " \
        "expected a JSON array like [{\"CNT\": n}], got:\n#{out}"
    end
    actual_count = parsed[0]['CNT'].to_i
    if actual_count != expected_count
      raise CommandFailed, "verify_landed_count! for #{database}.#{schema}.#{table}: " \
        "expected #{expected_count} rows to have landed, Snowflake COUNT(*) reports #{actual_count}"
    end
    actual_count
  end

  # Thin runner: writes `sql` to a temp file and runs it via the named `snow`
  # CLI connection. Raises CommandFailed (stdout+stderr embedded, same
  # error-text-embedding convention as sigma_rest.rb's Error) on any non-zero
  # exit rather than returning a status the caller might not check.
  # format_json: true adds `--format JSON` (CONFIRMED live: `snow sql
  # --connection <conn> --format JSON -q "SELECT COUNT(*) AS CNT FROM ...;"`
  # returns `[{"CNT": <n>}]`) — used by verify_landed_count! below, which
  # parses that JSON rather than the default ASCII-table output.
  def run_sql!(sql, connection:, runner: method(:system_run), format_json: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'load.sql')
      File.write(path, sql)
      cmd = ['snow', 'sql', '--connection', connection]
      cmd += ['--format', 'JSON'] if format_json
      cmd += ['-f', path]
      out, success = runner.call(cmd)
      raise CommandFailed, "snow sql (connection #{connection}) failed:\n#{out}" unless success
      out
    end
  end

  # Real subprocess call — the untested-offline half. Returns [combined_output, success_boolean].
  def system_run(cmd)
    out, status = Open3.capture2e(*cmd)
    [out, status.success?]
  end
end
