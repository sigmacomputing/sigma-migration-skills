#!/usr/bin/env ruby
# frozen_string_literal: true

# check-materialization-freshness.rb - is a materialized data-model element
# older than the warehouse tables it reads?
#
#   ruby scripts/check-materialization-freshness.rb --data-model <dmId> --workdir <WORK> \
#        [--connection <id>] [--folder <id>] [--out <WORK>/materialization-freshness.json] \
#        [--wait SECONDS] [--poll SECONDS (default 20)] [--rematerialize] [--allow-unknown] \
#        [--default-db DB] [--default-schema SCHEMA] [--replay <fixture.json>]
#
# Live flow (read-mostly): list the data model's materialization schedules (none -> NONE),
# read the DM spec, create ONE private scratch workbook with a table element per scheduled
# element, read its compiled queries (element -> t_mat table), ALWAYS delete the scratch
# workbook, then read INFORMATION_SCHEMA LAST_ALTERED for the t_mat + upstream tables through
# scripts/sigma-sql-probe.py. The materialization job API is deliberately NOT consulted: after
# a refresh it keeps reporting the first run's timestamps.
#
# --rematerialize POSTs :materialize for each STALE element (409 "already in progress" is
# tolerated) and then waits (default 600s) until the warehouse shows fresh data.
# --replay drives the same code path from a JSON fixture, fully offline:
#   {"schedules": [...], "dm_spec": {...}, "queries": {"entries": [...]},
#    "table_times": {"DB.S.T": {"last_altered": "...", "type": "BASE TABLE"}},
#    "table_times_sequence": [ {...}, {...} ]   # optional: one per poll, last one repeats
#   }
#
# Exit: 0 FRESH/NONE (and UNKNOWN with --allow-unknown), 3 STALE, 4 UNKNOWN, 2 usage/API error.

require 'json'
require 'optparse'
require 'time'
require 'tmpdir'
require 'open3'
require 'fileutils'
require_relative 'lib/materialization_freshness'
require_relative 'lib/materialization_schedules'
require_relative 'lib/py_resolve'

module FreshnessCLI
  module_function

  PROBE_WORKBOOK_NAME = 'zz migration freshness probe (scratch)'
  PROBE_SQL_NAME = 'zz migration freshness probe (sql scratch)'

  class UsageError < StandardError; end

  def parse_args(argv)
    opts = { poll: 20.0, wait: nil, rematerialize: false, allow_unknown: false }
    parser = OptionParser.new do |o|
      o.banner = 'Usage: check-materialization-freshness.rb --data-model ID --workdir DIR [options]'
      o.on('--data-model ID') { |v| opts[:dm] = v }
      o.on('--workdir DIR') { |v| opts[:workdir] = v }
      o.on('--connection ID') { |v| opts[:connection] = v }
      o.on('--folder ID') { |v| opts[:folder] = v }
      o.on('--out FILE') { |v| opts[:out] = v }
      o.on('--wait SECONDS', Float) { |v| opts[:wait] = v }
      o.on('--poll SECONDS', Float) { |v| opts[:poll] = v }
      o.on('--rematerialize') { opts[:rematerialize] = true }
      o.on('--allow-unknown') { opts[:allow_unknown] = true }
      o.on('--default-db DB') { |v| opts[:default_db] = v }
      o.on('--default-schema SCHEMA') { |v| opts[:default_schema] = v }
      o.on('--replay FILE') { |v| opts[:replay] = v }
      o.on('--scratch-name NAME', 'name prefix for the private scratch workbooks (always deleted)') { |v| opts[:scratch_name] = v }
      o.on('--report-clock PATH', 'report-clock.json (default: <workdir>/report-clock.json): ages clock-reading elements by the report day') { |v| opts[:report_clock] = v }
      o.on('--now ISO', 'evaluate "now" at this instant (tests / reproducing a run)') { |v| opts[:now] = v }
    end
    parser.parse!(argv)
    raise UsageError, '--workdir is required' unless opts[:workdir]
    raise UsageError, '--data-model is required (unless --replay)' unless opts[:dm] || opts[:replay]
    raise UsageError, '--poll must be > 0' unless opts[:poll] > 0
    opts[:out] ||= File.join(opts[:workdir], 'materialization-freshness.json')
    opts
  rescue OptionParser::ParseError => e
    raise UsageError, e.message
  end

  # ------------------------------------------------------------------ backends

  # Backend interface: schedules, dm_spec, queries, table_times(tables), rematerialize(sheet_id), cleanup.
  class ReplayBackend
    attr_reader :rematerialized

    def initialize(fixture)
      @f = fixture
      @polls = 0
      @rematerialized = []
    end

    def data_model_id
      @f['data_model_id'] || 'replay'
    end

    def schedules
      @f['schedules'] || []
    end

    def dm_spec
      @f['dm_spec'] || {}
    end

    def queries(_elements)
      [@f['queries'] || {}, {}]
    end

    def table_times(_tables)
      seq = @f['table_times_sequence']
      times =
        if seq.is_a?(Array) && !seq.empty?
          seq[[@polls, seq.length - 1].min]
        else
          @f['table_times'] || {}
        end
      @polls += 1
      [times, []]
    end

    def rematerialize(sheet_id)
      @rematerialized << sheet_id
      'replay-skipped'
    end

    def cleanup; end
  end

  class LiveBackend
    def initialize(opts)
      @opts = opts
      @dm = opts[:dm]
      @probe_wb = nil
    end

    def req(method, path, body = nil)
      require_relative 'lib/sigma_rest'
      Sigma.request(method, path, body: body && JSON.generate(body))
    end

    def data_model_id
      @dm
    end

    def wb_scratch_name
      @opts[:scratch_name] ? "#{@opts[:scratch_name]} (scratch)" : PROBE_WORKBOOK_NAME
    end

    def sql_scratch_name
      @opts[:scratch_name] ? "#{@opts[:scratch_name]} (sql scratch)" : PROBE_SQL_NAME
    end

    def schedules
      MaterializationSchedules.list(@dm, request: ->(m, p, b = nil) { req(m, p, b) })
    end

    def dm_spec
      @dm_spec ||= req(:get, "/v2/dataModels/#{@dm}/spec")
    end

    def folder_id
      @folder ||= @opts[:folder] || begin
        meta = req(:get, "/v2/dataModels/#{@dm}")
        (meta.is_a?(Hash) && meta['folderId']) || (dm_spec.is_a?(Hash) && dm_spec['folderId'])
      end
      raise UsageError, 'cannot determine a folder for the scratch workbook; pass --folder' unless @folder
      @folder
    end

    def connection_id
      @conn ||= @opts[:connection] || find_connection(dm_spec)
      raise UsageError, 'cannot determine a connection id; pass --connection' unless @conn
      @conn
    end

    def find_connection(node)
      case node
      when Hash
        return node['connectionId'] if node['connectionId'].is_a?(String)
        node.each_value do |v|
          found = find_connection(v)
          return found if found
        end
      when Array
        node.each do |v|
          found = find_connection(v)
          return found if found
        end
      end
      nil
    end

    def probe_contents(elements)
      spec = MaterializationFreshness.spec_elements(dm_spec)
      els = []
      lay = []
      map = {}
      elements.each_with_index do |s, i|
        eid = s['elementId']
        el = spec[eid]
        col = el && Array(el['columns']).first
        next unless col
        pid = "pe#{i}"
        map[pid] = eid
        ename = s['elementName'] || el['name'] || eid
        cname = col['name'] || col['id']
        els << { 'id' => pid, 'kind' => 'table', 'name' => ename,
                 'source' => { 'kind' => 'data-model', 'dataModelId' => @dm, 'elementId' => eid },
                 'columns' => [{ 'id' => 'c1', 'formula' => "[#{ename}/#{cname}]", 'name' => cname }] }
        lay << %(  <Element elementId="#{pid}" gridColumn="1 / 25" gridRow="#{els.length * 4 - 3} / #{els.length * 4 + 1}"/>)
      end
      layout = %(<?xml version="1.0" encoding="utf-8"?>\n) +
               %(<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">\n) +
               lay.join("\n") + "\n</Page>"
      [{ 'schemaVersion' => 1, 'kind' => 'workbook', 'pages' => [{ 'id' => 'p1', 'name' => 'Probe' }],
         'elements' => els, 'layout' => layout }, map]
    end

    # -> [queries body, probe_ids map]
    def queries(elements)
      unless @probe_wb
        contents, @probe_map = probe_contents(elements)
        return [{ 'entries' => [] }, @probe_map] if contents['elements'].empty?
        created = req(:post, '/v2/workbooks', { 'name' => wb_scratch_name, 'folderId' => folder_id, 'contents' => contents })
        @probe_wb = created['workbookId'] || created['id']
        raise "scratch workbook create returned no id: #{created.inspect[0, 200]}" unless @probe_wb
      end
      [req(:get, "/v2/workbooks/#{@probe_wb}/queries"), @probe_map]
    end

    def table_times(tables)
      stmts = MaterializationFreshness.information_schema_sql(tables)
      return [{}, []] if stmts.empty?
      Dir.mktmpdir('freshness-probe') do |dir|
        File.chmod(0o700, dir)
        inp = File.join(dir, 'in.json')
        out = File.join(dir, 'out.json')
        File.open(inp, 'w', 0o600) { |f| f.write(JSON.generate(stmts)) }
        # The probe state lives in the WORKDIR (not this tmpdir), so a scratch SQL workbook
        # left by a probe that raised before its own --cleanup is still found and deleted.
        state = File.join(@opts[:workdir], '.materialization-freshness-sql-probe.state.json')
        cmd = [*PyResolve.argv, File.join(__dir__, 'sigma-sql-probe.py'), '--in', inp, '--out', out,
               '--connection-id', connection_id, '--folder-id', folder_id, '--name', sql_scratch_name,
               '--state', state, '--cleanup', '--no-cache']
        begin
          # Not a shell: an argv array that runs this plugin's sigma-sql-probe.py with the resolved Python.
          # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
          _o, err, _st = Open3.capture3(*cmd)
        ensure
          FreshnessCLI.cleanup_probe_state(state, ->(id) { req(:delete, "/v2/files/#{id}") })
        end
        results = File.exist?(out) ? JSON.parse(File.read(out)) : {}
        errors = []
        rows = []
        stmts.each_key do |db|
          r = results[db]
          if r && r['ok']
            rows.concat(r['rows'] || [])
          else
            errors << "INFORMATION_SCHEMA query for #{db} failed: #{(r && r['error']) || err.to_s[0, 300]}"
          end
        end
        [MaterializationFreshness.table_times_from_rows(rows), errors]
      end
    end

    def rematerialize(sheet_id)
      req(:post, "/v2/dataModels/#{@dm}:materialize", { 'sheetId' => sheet_id })
      'started'
    rescue StandardError => e
      return 'already-in-progress' if e.message.include?(' 409')
      "error: #{e.message[0, 200]}"
    end

    def cleanup
      return unless @probe_wb
      begin
        req(:delete, "/v2/files/#{@probe_wb}")
      rescue StandardError => e
        warn "could not delete scratch workbook #{@probe_wb}: #{e.message[0, 200]}"
      end
      @probe_wb = nil
    end
  end

  # ------------------------------------------------------------------ run

  def snapshot(backend, schedules, opts)
    queries, probe_ids = backend.queries(schedules)
    elements = MaterializationFreshness.build_elements(
      schedules: schedules, dm_spec: backend.dm_spec, queries: queries, probe_ids: probe_ids,
      default_db: opts[:default_db], default_schema: opts[:default_schema]
    )
    tables = MaterializationFreshness.tables_to_fetch(elements)
    times, errors = backend.table_times(tables)
    result = MaterializationFreshness.evaluate(elements: elements, table_times: times)
    MaterializationFreshness.apply_report_day!(result, dm_spec: backend.dm_spec, timezone: report_timezone(opts),
                                               now: opts[:now] || Time.now.utc.iso8601)
    result['probe_errors'] = errors if errors.any?
    result
  end

  # Deletes a scratch workbook recorded in a sigma-sql-probe.py state file (it may
  # already be gone: errors are ignored) and removes the state.
  def cleanup_probe_state(path, deleter)
    return unless File.exist?(path)

    st = (JSON.parse(File.read(path)) rescue {})
    wid = st['workbookId']
    begin
      deleter.call(wid) if wid && st['created']
    rescue StandardError
      nil
    ensure
      File.delete(path) if File.exist?(path)
    end
  end

  def report_timezone(opts)
    path = opts[:report_clock] || File.join(opts[:workdir], 'report-clock.json')
    return nil unless File.exist?(path)

    JSON.parse(File.read(path))['report_timezone']
  rescue JSON::ParserError
    nil
  end

  def write_report(path, report)
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'w', 0o600) { |f| f.write(JSON.pretty_generate(report) + "\n") }
    File.chmod(0o600, path)
  end

  def summary(report)
    lines = ["materialization freshness: #{report['status']} (data model #{report['data_model_id']})"]
    Array(report['elements']).each do |e|
      lines << "  #{e['status'].ljust(16)} #{e['elementName'] || e['elementId']}"
      Array(e['reasons']).each { |r| lines << "      #{r}" }
    end
    if report['timed_out']
      lines << "  timed out after #{report['waited_s'].round(1)}s waiting for fresh data"
    end
    lines << '  Parity against this data model is NOT trustworthy until it is FRESH.' if report['status'] == 'STALE'
    lines.join("\n")
  end

  def exit_code(status, allow_unknown)
    case status
    when 'FRESH', 'NONE' then 0
    when 'UNKNOWN' then allow_unknown ? 0 : 4
    when 'STALE' then 3
    else 2
    end
  end

  def run(argv, out: $stdout, err: $stderr)
    opts = parse_args(argv.dup)
    backend =
      if opts[:replay]
        ReplayBackend.new(JSON.parse(File.read(opts[:replay])))
      else
        LiveBackend.new(opts)
      end
    dm_id = opts[:dm] || backend.data_model_id
    report = nil
    begin
      schedules = backend.schedules
      if schedules.empty?
        report = { 'status' => 'NONE', 'checked_at' => Time.now.utc.iso8601, 'data_model_id' => dm_id,
                   'counts' => {}, 'elements' => [] }
      else
        result = snapshot(backend, schedules, opts)
        remat = []
        wait_s = opts[:wait]
        if opts[:rematerialize] && result['status'] == 'STALE'
          result['elements'].select { |e| e['status'] == 'STALE' }.each do |e|
            remat << { 'elementId' => e['elementId'], 'sheetId' => e['sheetId'],
                       'result' => backend.rematerialize(e['sheetId']) }
          end
          wait_s ||= 600.0
        end
        waited = nil
        timed_out = false
        waitable = ->(r) { MaterializationFreshness.waitable?(r, report_day_stale: opts[:rematerialize]) }
        if wait_s && waitable.call(result)
          w = MaterializationFreshness.wait_until_fresh(
            evaluate_once: -> { snapshot(backend, schedules, opts) },
            deadline_s: wait_s, poll_s: opts[:poll],
            done: ->(r) { !waitable.call(r) }
          )
          result = w['result']
          waited = w['waited_s']
          timed_out = w['timed_out']
        end
        report = { 'status' => result['status'], 'checked_at' => Time.now.utc.iso8601, 'data_model_id' => dm_id,
                   'counts' => result['counts'], 'elements' => result['elements'] }
        report['probe_errors'] = result['probe_errors'] if result['probe_errors']
        report['allow_unknown'] = true if opts[:allow_unknown]
        report['rematerialize'] = remat unless remat.empty?
        report['waited_s'] = waited if waited
        report['timed_out'] = timed_out if waited
      end
    ensure
      backend.cleanup
    end
    write_report(opts[:out], report)
    out.puts summary(report)
    out.puts "report: #{opts[:out]}"
    exit_code(report['status'], opts[:allow_unknown])
  rescue UsageError => e
    err.puts "check-materialization-freshness: #{e.message}"
    2
  rescue StandardError => e
    err.puts "check-materialization-freshness: #{e.class}: #{e.message[0, 500]}"
    2
  end
end

exit(FreshnessCLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
