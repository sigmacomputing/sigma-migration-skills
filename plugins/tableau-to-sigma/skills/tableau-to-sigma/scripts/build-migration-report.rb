#!/usr/bin/env ruby
# frozen_string_literal: true

# Build a deterministic, converter-neutral migration completion report from the
# artifacts already present in a migration workdir.

require 'digest'
require 'json'
require 'optparse'
require 'pathname'
require 'time'

# lib/degradation_ledger.rb: vendored at scripts/lib/ in plugins, canonical at
# ../lib/ in shared/. Optional: without it the report lists no platform differences.
_ledger_lib = [File.join(__dir__, 'lib', 'degradation_ledger.rb'),
               File.join(__dir__, '..', 'lib', 'degradation_ledger.rb')].find { |f| File.file?(f) }
require _ledger_lib if _ledger_lib

class MigrationReportError < StandardError; end

class MigrationReport
  TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze
  STATUS_ALIASES = {
    'migrated' => 'migrated', 'complete' => 'migrated',
    'completed' => 'migrated', 'converted' => 'migrated',
    'built' => 'migrated', 'emitted' => 'migrated',
    'resolved' => 'migrated', 'pass' => 'migrated', 'passed' => 'migrated',
    'approximated' => 'approximated', 'approximate' => 'approximated',
    'approximation' => 'approximated', 'substituted' => 'approximated',
    'needs-review' => 'needs-review', 'review' => 'needs-review',
    'pending-review' => 'needs-review', 'unresolved' => 'needs-review',
    'needs-wiring' => 'needs-review', 'needs-materialization' => 'needs-review',
    'degraded' => 'needs-review', 'partial' => 'needs-review',
    'skipped' => 'skipped', 'skip' => 'skipped', 'dropped' => 'skipped',
    'omitted' => 'skipped', 'excluded' => 'skipped', 'not-emitted' => 'skipped',
    # A control the builder decided not to place (nothing reads it): the source
    # parameter exists and was explicitly left out, so it is skipped, not
    # migrated (and not not-applicable: the source dashboard still shows it).
    'dropped-unused' => 'skipped',
    # A parameter control the source dashboard shows but nothing reads (inert in the source
    # too): built and visible, so it is an approximation, not a skip.
    'source-inert' => 'approximated',
    'not-applicable' => 'not-applicable', 'n-a' => 'not-applicable',
    'na' => 'not-applicable'
  }.freeze
  STATUS_KEYS = %w[terminal_status terminalStatus migration_status migrationStatus
                   accounting_status accountingStatus status outcome disposition
                   result severity].freeze
  RECORD_KEYS = %w[objects source_objects accounting statuses records coverage
                   detail unresolved items].freeze
  ID_KEYS = %w[id object_id objectId source_object_id sourceObjectId source_id
               sourceId luid guid key].freeze
  NAME_KEYS = %w[name object_name objectName source_object_name sourceObjectName
                 title visual control].freeze
  TYPE_KEYS = %w[type object_type objectType source_type sourceType kind].freeze
  INVENTORY_NAMES = %w[source-inventory.json source-object-census.json inventory.json].freeze
  FAIL_WORDS = %w[fail failed failure error red unhealthy blank divergent
                  not-executable high-risk risky].freeze
  PASS_WORDS = %w[pass passed ok green healthy clear no-risk success successful].freeze
  # The census's needs-review rationale for an object that IS built but that
  # final parity does not name (build-source-object-census.rb, account_objects).
  # It is an absence of proof, not evidence against the build, so it does not
  # contradict a migrated status from an artifact that saw the object built.
  UNPROVEN_BUILT_DETAIL = 'matching built object exists, but final parity does not prove this source object'

  attr_reader :document

  def initialize(workdir, inventory_path)
    @workdir = File.expand_path(workdir)
    @inventory_path = File.expand_path(inventory_path)
    @artifacts = []
    @artifact_docs = {}
    @input_errors = []
    @unknown_records = []
    @duplicate_inventory = []
    @unproven_built = []
    @source_inert = []
    @objects = []
  end

  def build
    inventory = read_json!(@inventory_path)
    add_artifact('inventory', @inventory_path, true)
    load_optional_artifacts
    normalize_inventory(inventory)
    collect_inventory_accounting(inventory)
    collect_external_accounting
    finalize_objects

    checks = []
    checks << accounting_check
    checks << status_consistency_check
    checks << artifact_consistency_check
    checks << controls_check
    checks << parity_check
    checks << render_check
    checks << blank_risk_check
    gates = finalize_gates_check
    checks << gates if gates

    hard_failure = checks.any? { |c| c['status'] == 'FAIL' }
    yellow = @objects.any? { |o| %w[approximated needs-review skipped].include?(o['status']) }
    yellow ||= waiver_entries.any? || degradation_entries.any? || !visual_degradation.nil?
    verdict = hard_failure ? 'RED' : (yellow ? 'YELLOW' : 'GREEN')

    counts = TERMINAL.each_with_object({}) { |status, out| out[status] = 0 }
    @objects.each { |object| counts[object['status']] += 1 if counts.key?(object['status']) }
    accounted = @objects.count { |object| TERMINAL.include?(object['status']) }

    @document = {
      'schema_version' => 1,
      'verdict' => verdict,
      'summary' => {
        'total' => @objects.length,
        'accounted' => accounted,
        'complete' => accounted == @objects.length &&
                      @objects.none? { |object| object['status'] == 'contradictory' },
        'counts' => counts
      },
      'source_objects' => @objects,
      'checks' => checks,
      'artifacts' => @artifacts.sort_by { |a| [a['kind'], a['path']] },
      'degradations' => document_degradations,
      'platform_differences' => platform_difference_entries,
      'polish_notes' => polish_note_entries,
      'waivers' => waiver_entries
    }
    add_generated_at
    @document
  end

  def markdown
    doc = @document || build
    counts = doc['summary']['counts']
    lines = []
    lines << '# Migration Report'
    lines << ''
    lines << "Verdict: **#{doc['verdict']}**"
    lines << ''
    lines << "Accounting: **#{doc['summary']['accounted']}/#{doc['summary']['total']}** source objects have exactly one terminal status."
    lines << ''
    lines << '## Summary'
    lines << ''
    lines << '| Status | Count |'
    lines << '| --- | ---: |'
    TERMINAL.each { |status| lines << "| #{status} | #{counts[status]} |" }
    lines << ''
    lines << '## Checks'
    lines << ''
    lines << '| Check | Result | Detail |'
    lines << '| --- | --- | --- |'
    doc['checks'].each do |check|
      lines << "| #{md(check['name'])} | #{check['status']} | #{md(check['message'])} |"
    end
    lines << ''
    lines << '## Source object accounting'
    lines << ''
    lines << '| Type | ID | Name | Terminal status | Evidence |'
    lines << '| --- | --- | --- | --- | --- |'
    doc['source_objects'].each do |object|
      evidence = object['status_sources'].map { |source| source['artifact'] }.uniq.join(', ')
      lines << "| #{md(object['type'])} | #{md(object['id'])} | #{md(object['name'])} | #{md(object['status'])} | #{md(evidence)} |"
    end
    lines << ''
    lines << '## Artifacts'
    lines << ''
    lines << '| Kind | Path | Present |'
    lines << '| --- | --- | --- |'
    doc['artifacts'].each do |artifact|
      lines << "| #{md(artifact['kind'])} | #{md(artifact['path'])} | #{artifact['present'] ? 'yes' : 'no'} |"
    end
    append_entries(lines, 'Degradations', doc['degradations'])
    append_platform_differences(lines, doc['platform_differences'])
    append_polish_notes(lines, doc['polish_notes'])
    append_entries(lines, 'Waivers', doc['waivers'])
    lines.join("\n") + "\n"
  end

  private

  def read_json!(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    raise MigrationReportError, "missing JSON artifact: #{path}"
  rescue JSON::ParserError => e
    raise MigrationReportError, "malformed JSON artifact #{path}: #{e.message}"
  rescue Errno::EACCES => e
    raise MigrationReportError, "cannot read JSON artifact #{path}: #{e.message}"
  end

  def load_optional_artifacts
    fixed = {
      'coverage' => 'coverage.json',
      'degradation-ledger' => 'degradation-ledger.json',
      'parity' => 'parity-final.json',
      'waivers' => 'waivers.json'
    }
    fixed.each do |kind, basename|
      path = File.join(@workdir, basename)
      load_artifact(kind, path)
    end

    Dir.glob(File.join(@workdir, '*-controls-coverage.json')).sort.each do |path|
      load_artifact('controls-coverage', path)
    end
    discover_health_artifacts('render-health', [
                                '*render-health*.json', '*render_health*.json',
                                'render-health/**/*.json', 'render_health/**/*.json'
                              ])
    add_artifact('render-health', File.join(@workdir, 'render-health.json'), false) if
      @artifacts.none? { |artifact| artifact['kind'] == 'render-health' }
    discover_health_artifacts('blank-risk', [
                                '*blank-risk*.json', '*blank_risk*.json',
                                'blank-risk/**/*.json', 'blank_risk/**/*.json'
                              ])
    add_artifact('blank-risk', File.join(@workdir, 'blank-risk.json'), false) if
      @artifacts.none? { |artifact| artifact['kind'] == 'blank-risk' }
    # Machine render evidence written by the gates themselves (gate-14's
    # visual-similarity floor and the anchors tile census). Recorded only when
    # present, like the health artifacts above.
    %w[visual-similarity anchors-verdict finalize-gates].each do |kind|
      path = File.join(@workdir, "#{kind}.json")
      load_artifact(kind, path) if File.file?(path)
    end
  end

  def discover_health_artifacts(kind, globs)
    paths = globs.flat_map { |pattern| Dir.glob(File.join(@workdir, pattern)) }
    paths.select { |path| File.file?(path) }.uniq.sort.each { |path| load_artifact(kind, path) }
  end

  def load_artifact(kind, path)
    unless File.file?(path)
      add_artifact(kind, path, false) unless kind == 'controls-coverage' ||
                                                   kind == 'render-health' ||
                                                   kind == 'blank-risk'
      return
    end
    @artifact_docs[path] = read_json!(path)
    add_artifact(kind, path, true)
  end

  def add_artifact(kind, path, present)
    @artifacts << { 'kind' => kind, 'path' => display_path(path), 'present' => present }
  end

  def display_path(path)
    expanded = File.expand_path(path)
    Pathname.new(expanded).relative_path_from(Pathname.new(@workdir)).to_s
  rescue ArgumentError
    expanded
  end

  def normalize_inventory(doc)
    rows = inventory_rows(doc)
    raise MigrationReportError, 'source inventory contains no recognizable objects' if rows.empty?

    seen = {}
    rows.each_with_index do |pair, index|
      raw, inferred_type = pair
      unless raw.is_a?(Hash)
        @input_errors << "inventory object #{index} is not a JSON object"
        next
      end
      type = first_value(raw, TYPE_KEYS).to_s.strip
      type = singularize(inferred_type) if type.empty?
      type = 'object' if type.empty?
      # id/name keep their whitespace: Tableau allows sheets named "X", "X "
      # and "X  ", which are distinct source objects.
      id = first_value(raw, ID_KEYS).to_s
      name = first_value(raw, NAME_KEYS).to_s
      if id.empty? && name.empty?
        @input_errors << "inventory object #{index} has neither id nor name"
        next
      end
      key = object_key(type, id, name)
      if seen.key?(key)
        @duplicate_inventory << key
        next
      end
      object = {
        'key' => key,
        'type' => type,
        'id' => id,
        'name' => name,
        'status' => 'missing',
        'status_sources' => [],
        '_raw' => raw
      }
      seen[key] = object
      @objects << object
    end
    raise MigrationReportError, @input_errors.join('; ') unless @input_errors.empty?
    # Raw id/name break ties between names that fold equal ("X" / "X "), so the
    # order stays deterministic (sort_by is not stable).
    @objects.sort_by! do |object|
      [fold(object['type']), fold(object['id']), fold(object['name']), object['id'], object['name']]
    end
  end

  def inventory_rows(doc)
    return doc.map { |object| [object, 'object'] } if doc.is_a?(Array)
    raise MigrationReportError, 'source inventory must be a JSON object or array' unless doc.is_a?(Hash)

    %w[objects source_objects sourceObjects inventory items].each do |key|
      value = doc[key]
      return rows_from_container(value, key) if value.is_a?(Array) || value.is_a?(Hash)
    end

    ignored = %w[summary metadata accounting statuses records coverage checks artifacts waivers]
    rows = []
    doc.keys.sort.each do |key|
      value = doc[key]
      next if ignored.include?(key) || !value.is_a?(Array)
      value.each { |object| rows << [object, key] }
    end
    rows
  end

  def rows_from_container(container, default_type)
    return container.map { |object| [object, default_type] } if container.is_a?(Array)
    rows = []
    container.keys.sort.each do |type|
      value = container[type]
      if value.is_a?(Array)
        value.each { |object| rows << [object, type] }
      elsif value.is_a?(Hash) && status_from(value)
        rows << [value.merge('id' => type), default_type]
      end
    end
    rows
  end

  def collect_inventory_accounting(doc)
    @objects.each do |object|
      add_status_from_record(object, object.delete('_raw'), display_path(@inventory_path))
    end
    records_from_document(doc, false).each_with_index do |pair, index|
      record, inferred_type = pair
      apply_record(record, inferred_type, "#{display_path(@inventory_path)}#accounting[#{index}]")
    end
  end

  def collect_external_accounting
    @artifact_docs.keys.sort.each do |path|
      next unless artifact_kind(path) == 'coverage' || artifact_kind(path) == 'controls-coverage'
      records_from_document(@artifact_docs[path], true).each_with_index do |pair, index|
        record, inferred_type = pair
        apply_record(record, inferred_type, "#{display_path(path)}#record[#{index}]")
      end
    end
  end

  def records_from_document(doc, external)
    return doc.map { |record| [record, nil] } if doc.is_a?(Array)
    return [] unless doc.is_a?(Hash)
    rows = []
    keys = external ? RECORD_KEYS : %w[accounting statuses records coverage]
    keys.each do |key|
      value = doc[key]
      next if value.nil?
      rows.concat(records_from_container(value, nil))
    end
    rows
  end

  def records_from_container(container, inferred_type)
    if container.is_a?(Array)
      return container.select { |record| record.is_a?(Hash) }.map { |record| [record, inferred_type] }
    end
    return [] unless container.is_a?(Hash)
    if status_from(container) &&
       !(first_value(container, ID_KEYS).nil? && first_value(container, NAME_KEYS).nil?)
      return [[container, inferred_type]]
    end
    rows = []
    container.keys.sort.each do |key|
      value = container[key]
      if value.is_a?(Array)
        value.each { |record| rows << [record, key] if record.is_a?(Hash) }
      elsif value.is_a?(Hash)
        rows << [value.merge('id' => key), inferred_type]
      elsif normalize_status(value)
        rows << [{ 'id' => key, 'status' => value }, inferred_type]
      end
    end
    rows
  end

  def apply_record(record, inferred_type, source)
    return unless record.is_a?(Hash)
    status = status_from(record)
    return unless status
    ref = record['source_object'].is_a?(Hash) ? record['source_object'] :
          (record['object'].is_a?(Hash) ? record['object'] : record)
    type = first_value(ref, TYPE_KEYS).to_s.strip
    type = singularize(inferred_type) if type.empty?
    # Unstripped: match_object tries the exact spelling before the folded one.
    id = first_value(ref, ID_KEYS).to_s
    name = first_value(ref, NAME_KEYS).to_s
    object = match_object(type, id, name)
    if object
      add_status(object, status, source, record)
    elsif !id.strip.empty? || !name.strip.empty?
      @unknown_records << "#{source} refers to unknown #{type.empty? ? 'object' : type} #{id.strip.empty? ? name : id}"
    end
  end

  def add_status_from_record(object, record, source)
    status = status_from(record)
    add_status(object, status, source, record) if status
    unproven = Array(record['evidence']).any? do |item|
      item.is_a?(Hash) && item['detail'].to_s == UNPROVEN_BUILT_DETAIL
    end
    @unproven_built << [object['key'], source] if status == 'needs-review' && unproven
    accounting = record['accounting']
    direct_accounting = normalize_status(accounting)
    add_status(object, direct_accounting, "#{source}#object-accounting", record) if direct_accounting
    if accounting.is_a?(Hash)
      nested_status = status_from(accounting)
      add_status(object, nested_status, "#{source}#object-accounting", accounting) if nested_status
    elsif accounting.is_a?(Array)
      accounting.each_with_index do |entry, index|
        next unless entry.is_a?(Hash)
        nested_status = status_from(entry)
        add_status(object, nested_status, "#{source}#object-accounting[#{index}]", entry) if nested_status
      end
    end
  end

  def add_status(object, status, source, record)
    detail = record['reason'] || record['detail'] || record['notes'] || record['evidence']
    evidence = { 'status' => status, 'artifact' => source }
    evidence['detail'] = detail.to_s unless detail.nil? || detail.to_s.empty?
    object['status_sources'] << evidence unless object['status_sources'].include?(evidence)
    @source_inert << object['key'] if STATUS_KEYS.any? { |key| record[key].to_s.strip.downcase == 'source-inert' }
  end

  def finalize_objects
    @objects.each do |object|
      statuses = object['status_sources'].map { |source| source['status'] }.uniq
      object['status'] = if statuses.empty?
                           'missing'
                         elsif statuses.length == 1
                           statuses.first
                         elsif source_inert_approximation?(object, statuses)
                           'approximated'
                         elsif unproven_built_only?(object, statuses)
                           'needs-review'
                         else
                           'contradictory'
                         end
    end
  end

  def source_inert_approximation?(object, statuses)
    return false unless @source_inert.include?(object['key'])
    return false unless statuses.include?('approximated') &&
                        (statuses - %w[approximated migrated needs-review]).empty?
    object['status_sources'].select { |source| source['status'] == 'needs-review' }.all? do |source|
      @unproven_built.include?([object['key'], source['artifact']])
    end
  end

  # migrated + needs-review is NOT a contradiction when every needs-review
  # record is the census's "built, but parity does not prove it" rationale: one
  # artifact saw the object built, the other merely lacks proof. The conservative
  # status wins and both evidence entries stay on the object. Every other mix
  # (migrated vs skipped, or a census "no matching built object" vs migrated) is
  # a real conflict and stays contradictory.
  def unproven_built_only?(object, statuses)
    return false unless statuses.sort == %w[migrated needs-review]
    object['status_sources'].select { |source| source['status'] == 'needs-review' }.all? do |source|
      @unproven_built.include?([object['key'], source['artifact']])
    end
  end

  # Resolve a status record to ONE inventory object, or nil when it cannot be
  # done without guessing. The id is tried before the name, and within each the
  # EXACT spelling (unstripped, case-sensitive) before the folded one: Tableau
  # allows worksheets named "X", "X " and "X  ", which all fold to "x" and would
  # otherwise be mutually ambiguous.
  def match_object(type, id, name)
    [id, name].zip(%w[id name]).each do |value, field|
      next if value.strip.empty?
      [->(object) { object[field] == value },
       ->(object) { fold(object[field]) == fold(value) }].each do |same|
        found = resolve_candidates(@objects.select(&same), type)
        return found if found
      end
    end
    nil
  end

  def resolve_candidates(candidates, type)
    unless type.empty?
      typed = candidates.select { |object| fold(object['type']) == fold(type) }
      return typed.first if typed.length == 1
    end
    return candidates.first if candidates.length == 1
    route_worksheet_or_zone(candidates, type)
  end

  # A worksheet and the dashboard zone(s) that place it share its name (always
  # true for a sheet on a dashboard), so a record with a missing type, or a type
  # that names neither (a coverage.json `chart` / `visual` record), is ambiguous
  # between them. Rule: such a record describes the SOURCE WORKSHEET, so it
  # routes to the single worksheet candidate; the zones keep the status the
  # census derived for them. A record that does name the zone type but cannot
  # pick one zone (no id) stays ambiguous, and any candidate set that includes
  # another object type (e.g. a dashboard) is never guessed.
  def route_worksheet_or_zone(candidates, type)
    return nil unless candidates.all? { |object| %w[worksheet dashboard-zone].include?(object['type']) }
    worksheets = candidates.select { |object| object['type'] == 'worksheet' }
    return nil unless worksheets.length == 1
    return nil if fold(type) == 'dashboard-zone'
    worksheets.first
  end

  def accounting_check
    missing = @objects.select { |object| object['status'] == 'missing' }
    contradictory = @objects.select { |object| object['status'] == 'contradictory' }
    if missing.empty? && contradictory.empty?
      check('source-accounting', 'PASS', "#{@objects.length}/#{@objects.length} source objects accounted for")
    else
      parts = []
      parts << "missing: #{missing.map { |o| o['key'] }.join(', ')}" unless missing.empty?
      parts << "contradictory: #{contradictory.map { |o| o['key'] }.join(', ')}" unless contradictory.empty?
      check('source-accounting', 'FAIL', parts.join('; '))
    end
  end

  def status_consistency_check
    errors = []
    errors << "duplicate inventory identities: #{@duplicate_inventory.uniq.sort.join(', ')}" unless @duplicate_inventory.empty?
    errors.concat(@unknown_records.sort)
    contradictory = @objects.select { |object| object['status'] == 'contradictory' }
    contradictory.each do |object|
      statuses = object['status_sources'].map { |source| source['status'] }.uniq.sort
      errors << "#{object['key']} has statuses #{statuses.join(' and ')}"
    end
    errors.empty? ? check('status-consistency', 'PASS', 'no duplicate contradictory status records') :
                    check('status-consistency', 'FAIL', errors.join('; '))
  end

  def artifact_consistency_check
    errors = []
    inventory = @artifact_docs[@inventory_path] || read_json!(@inventory_path)
    summary = inventory.is_a?(Hash) ? inventory['summary'] : nil
    if summary.is_a?(Hash)
      declared = first_numeric(summary, %w[total total_objects totalObjects source_objects
                                           sourceObjects object_count objectCount count])
      errors << "inventory summary total #{declared} != #{@objects.length}" if declared && declared != @objects.length
      TERMINAL.each do |status|
        declared_status = numeric_value(summary, status) || numeric_value(summary, status.tr('-', '_'))
        next unless declared_status
        actual = @objects.count { |object| summary_status(object) == status }
        errors << "inventory summary #{status}=#{declared_status} != #{actual}" if declared_status != actual
      end
    end
    ledger_path = File.join(@workdir, 'degradation-ledger.json')
    ledger = @artifact_docs[ledger_path]
    if ledger.is_a?(Hash) && ledger['counts'].is_a?(Hash)
      actual = Hash.new(0)
      Array(ledger['entries']).each { |entry| actual[entry['class'].to_s] += 1 if entry.is_a?(Hash) }
      (ledger['counts'].keys.map(&:to_s) | actual.keys).sort.each do |klass|
        count = ledger['counts'][klass]
        errors << "degradation ledger #{klass}=#{count || 0} != #{actual[klass]}" if integer(count || 0) != actual[klass]
      end
    end
    waiver_path = File.join(@workdir, 'waivers.json')
    waiver_doc = @artifact_docs[waiver_path]
    if waiver_doc.is_a?(Hash)
      declared = first_numeric(waiver_doc, %w[count waiver_count waiverCount])
      entries = Array(waiver_doc['waivers'])
      errors << "waivers count #{declared} != #{entries.length}" if declared && declared != entries.length
    end
    parity = @artifact_docs[File.join(@workdir, 'parity-final.json')]
    if parity.is_a?(Hash)
      declared = first_numeric(parity, %w[waiver_count waiverCount])
      entries = Array(parity['waivers'])
      errors << "parity waiver_count #{declared} != #{entries.length}" if declared && declared != entries.length
    end
    errors.empty? ? check('artifact-consistency', 'PASS', 'artifact summaries agree with detail records') :
                    check('artifact-consistency', 'FAIL', errors.join('; '))
  end

  def summary_status(object)
    return object['status'] unless object['status'] == 'approximated' &&
                                   @source_inert.include?(object['key'])
    inventory_source = display_path(@inventory_path)
    object['status_sources'].find { |source| source['artifact'] == inventory_source }&.fetch('status') ||
      object['status']
  end

  def controls_check
    paths = paths_for_kind('controls-coverage')
    return check('controls-coverage', 'PASS', 'no controls coverage artifact supplied') if paths.empty?
    malformed = paths.select do |path|
      doc = @artifact_docs[path]
      !doc.is_a?(Hash) || !doc['detail'].is_a?(Array)
    end
    return check('controls-coverage', 'FAIL', "malformed detail rows: #{malformed.map { |p| display_path(p) }.join(', ')}") unless malformed.empty?
    rows = paths.sum { |path| @artifact_docs[path]['detail'].length }
    check('controls-coverage', 'PASS', "#{rows} source control records consumed")
  end

  def parity_check
    path = File.join(@workdir, 'parity-final.json')
    doc = @artifact_docs[path]
    return check('parity', 'FAIL', 'parity-final.json is missing') unless doc.is_a?(Hash)
    state = normalized_state(doc)
    errors = []
    errors << "parity status is #{state || 'not recorded'}" unless PASS_WORDS.include?(state)
    passed = first_numeric(doc, %w[charts_pass passed pass])
    total = first_numeric(doc, %w[charts_total total])
    errors << "charts_pass #{passed} != charts_total #{total}" if passed && total && passed != total
    oracle = anchors_oracle_detail(doc) if total&.zero?
    return check('parity', 'PASS', oracle) if oracle
    errors.empty? ? check('parity', 'PASS', state || 'pass') :
                    check('parity', 'FAIL', errors.join('; '))
  end

  # An empty chart pool (every worksheet hidden, no exportable view data) passes
  # only through the hard gate's anchors-oracle substitution, which stamps
  # parity_oracle bound to the anchors-verdict.json it accepted.
  def anchors_oracle_detail(doc)
    stamp = doc['parity_oracle']
    return nil unless stamp.is_a?(Hash) && stamp['kind'] == 'anchors'
    verdict = File.join(@workdir, 'anchors-verdict.json')
    return nil unless File.file?(verdict) &&
                      Digest::SHA256.file(verdict).hexdigest == stamp['anchors_verdict_sha256']
    "no exportable chart data; anchors oracle stands in (#{stamp['anchors_matched']}/#{stamp['anchors_checked']} " \
      "anchors matched, #{stamp['tiles_covered']}/#{stamp['tiles_displayed']} displayed tiles covered)"
  end

  # visual-similarity.json is render evidence only through its render_health
  # record (written by png_health.py). Returns nil when there is nothing to
  # vouch with, else [state, reason]; a recorded render image that no longer
  # exists or a non-PASS health status is :fail. A majority of measured tiles
  # being blank is also a render-health failure: the same majority rule as
  # visual-similarity.py, but armed at any measured count (> 0) on purpose.
  # png_health's whole-image check only catches all-white, solid or near-empty
  # images, so a page with chrome but 1-of-1 or 2-of-2 blank tiles passes it;
  # visual-similarity.py's TILE_MIN_MEASURED = 3 only guards the composite score
  # against noise. Otherwise the artifact's composite pass flag is
  # visual-fidelity evidence, not render-health evidence.
  def visual_similarity_evidence
    doc = @artifact_docs[File.join(@workdir, 'visual-similarity.json')]
    return nil unless doc.is_a?(Hash) && doc['render_health'].is_a?(Hash)
    health = doc['render_health']
    image = health['path']
    if image.is_a?(String) && !image.strip.empty? &&
       !File.file?(File.expand_path(image, @workdir))
      return [:fail, "render image missing: #{image}"]
    end
    blank = doc['tiles_blank']
    raw_measured = doc['tiles_measured']
    measured = if raw_measured.is_a?(Integer) then raw_measured
               elsif raw_measured.is_a?(String) && raw_measured.match?(/\A\d+\z/) then raw_measured.to_i
               else 0
               end
    if blank.is_a?(Array) && measured > 0 && 2 * blank.length > measured
      return [:fail, "#{blank.length} of #{measured} tiles blank"]
    end
    status = fold(health['status'])
    return [:fail, "render_health status #{health['status']}"] if !status.empty? && status != 'pass'
    return nil if status.empty?
    [:pass, nil]
  end

  # tiles_all_nonempty from the anchors tile census: true / false / nil.
  def anchors_tile_census
    doc = @artifact_docs[File.join(@workdir, 'anchors-verdict.json')]
    return nil unless doc.is_a?(Hash)
    value = doc['tiles_all_nonempty']
    boolean?(value) ? value : nil
  end

  def empty_tiles_waived?
    waiver_entries.any? do |entry|
      entry['flag'] == '--allow-empty-tiles' || entry['reason'] == '--allow-empty-tiles'
    end
  end

  def render_check
    paths = paths_for_kind('render-health')
    results = paths.map { |path| [path, health_state(@artifact_docs[path], 'render')] }
    similarity = visual_similarity_evidence
    if similarity
      results << [File.join(@workdir, 'visual-similarity.json'), similarity[0], similarity[1]]
    end
    parity = @artifact_docs[File.join(@workdir, 'parity-final.json')]
    if parity.is_a?(Hash) &&
       (parity.key?('visual_checked') || parity.key?('visual_verdict'))
      verdict = fold(parity['visual_verdict'])
      checked = parity['visual_checked']
      visual_pass = if parity.key?('visual_checked')
                      checked == true && (verdict.empty? || verdict == 'pass')
                    else
                      verdict == 'pass'
                    end
      # Only a positive visual pass is render evidence. A divergent or
      # not-executable verdict is a recorded fidelity residual (YELLOW via
      # visual_degradation), never an unhealthy render.
      results << [File.join(@workdir, 'parity-final.json'), :pass] if visual_pass
    end
    return check('render-health', 'FAIL', 'no healthy render evidence found') if results.empty?
    failed = results.select { |pair| pair[1] != :pass }
    unless failed.empty?
      labels = failed.map { |p| p[2] ? "#{display_path(p[0])} (#{p[2]})" : display_path(p[0]) }
      return check('render-health', 'FAIL', "unhealthy or indeterminate: #{labels.join(', ')}")
    end
    check('render-health', 'PASS', "#{results.length} render health record(s) healthy")
  end

  # finalize-gates.json: the converter's finalize battery records each gate's
  # PASS/FAIL before building this report (tableau-to-sigma --finalize). A
  # failed gate makes the report a FAIL check (RED): the report must never say
  # GREEN while a hard gate failed (2026-11-09 Complex Pivot: gate 14 failed,
  # finalize NOT GREEN, verify-complete NOT DONE, report GREEN). Absent file ->
  # no check (other converters, standalone runs).
  def finalize_gates_check
    doc = @artifact_docs[File.join(@workdir, 'finalize-gates.json')]
    return nil if doc.nil?
    gates = doc.is_a?(Hash) ? doc['gates'] : nil
    return check('finalize-gates', 'FAIL', 'finalize-gates.json is malformed (no gates object)') unless gates.is_a?(Hash) && !gates.empty?
    failed = gates.reject { |_name, row| fold(row.is_a?(Hash) ? row['status'] : row) == 'pass' }
    return check('finalize-gates', 'PASS', "#{gates.length} finalize gate(s) passed") if failed.empty?
    names = failed.map { |name, row| row.is_a?(Hash) && row['exit'] ? "#{name} (exit #{row['exit']})" : name.to_s }
    check('finalize-gates', 'FAIL', "finalize gate(s) failed: #{names.join(', ')}")
  end

  def blank_risk_check
    paths = paths_for_kind('blank-risk')
    results = paths.map { |path| [path, health_state(@artifact_docs[path], 'blank')] }
    failed = results.select { |pair| pair[1] == :fail }
    return check('blank-risk', 'FAIL', "blank risk detected: #{failed.map { |p| display_path(p[0]) }.join(', ')}") unless failed.empty?
    unknown = results.select { |pair| pair[1] == :unknown }
    return check('blank-risk', 'FAIL', "blank risk indeterminate: #{unknown.map { |p| display_path(p[0]) }.join(', ')}") unless unknown.empty?
    # Any unwaived explicit FAIL signal wins, even over a clear blank-risk
    # artifact: the tile census saw empty displayed tiles.
    census = anchors_tile_census
    if census == false
      return check('blank-risk', 'PASS', 'empty displayed tiles accepted via --allow-empty-tiles') if empty_tiles_waived?
      return check('blank-risk', 'FAIL', 'anchors tile census found empty displayed tiles')
    end
    similarity = visual_similarity_evidence
    if paths.empty?
      render = paths_for_kind('render-health')
      return check('blank-risk', 'PASS', 'covered by healthy render evidence') unless render.empty?
      return check('blank-risk', 'PASS', 'covered by anchors tile census') if census == true
      return check('blank-risk', 'PASS', 'covered by healthy render evidence') if similarity && similarity[0] == :pass
      parity = @artifact_docs[File.join(@workdir, 'parity-final.json')]
      # A recorded blind comparison (pass or divergent, with its screenshot)
      # looked at the rendered page, so it covers blank risk.
      shot = parity.is_a?(Hash) ? parity['screenshot_path'] : nil
      has_shot = shot.is_a?(String) && !shot.strip.empty?
      verdict = parity.is_a?(Hash) ? fold(parity['visual_verdict']) : ''
      compared = parity.is_a?(Hash) &&
                 (parity['visual_checked'] == true || verdict == 'pass' ||
                  (verdict == 'divergent' && has_shot))
      return check('blank-risk', compared ? 'PASS' : 'FAIL',
                   compared ? 'covered by recorded visual comparison' : 'no blank-risk evidence found')
    end
    check('blank-risk', 'PASS', "#{paths.length} blank-risk record(s) clear")
  end

  def health_state(value, kind)
    signals = []
    walk_health(value, kind, signals)
    return :fail if signals.include?(:fail)
    return :pass if signals.include?(:pass)
    :unknown
  end

  def walk_health(value, kind, signals)
    case value
    when Array
      value.each { |item| walk_health(item, kind, signals) }
    when Hash
      value.each do |key, item|
        normalized_key = key.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase.tr('-', '_')
        if %w[status verdict result health state].include?(normalized_key)
          word = fold(item)
          signals << :fail if FAIL_WORDS.include?(word)
          signals << :pass if PASS_WORDS.include?(word)
        elsif normalized_key =~ /(?:healthy|health_ok)\z/ && boolean?(item)
          signals << (item ? :pass : :fail)
        elsif %w[healthy ok passed success].include?(normalized_key) && boolean?(item)
          signals << (item ? :pass : :fail)
        elsif %w[rendered render_success valid].include?(normalized_key) && boolean?(item)
          signals << (item ? :pass : :fail)
        elsif normalized_key == 'risk' && boolean?(item)
          signals << (item ? :fail : :pass)
        elsif normalized_key =~ /risk/ && item.is_a?(String)
          signals << :fail if %w[high high-risk risky red].include?(fold(item))
          signals << :pass if %w[none low clear no-risk green].include?(fold(item))
        elsif normalized_key =~ /(?:blank|failure|failed|error).*count/ && numeric?(item)
          signals << (item.to_f.positive? ? :fail : :pass)
        elsif %w[failures failed errors blank_count].include?(normalized_key) && numeric?(item)
          signals << (item.to_f.positive? ? :fail : :pass)
        elsif %w[failures errors].include?(normalized_key) && item.is_a?(Array)
          signals << (item.empty? ? :pass : :fail)
        elsif normalized_key =~ /(?:blank_risk|at_risk|is_blank)/ && boolean?(item)
          signals << (item ? :fail : :pass)
        elsif normalized_key == 'blank' && boolean?(item)
          signals << (item ? :fail : :pass)
        end
        walk_health(item, kind, signals) if item.is_a?(Hash) || item.is_a?(Array)
      end
    end
  end

  # A divergent / not-executable blind visual verdict is a fidelity residual:
  # it caps the run at YELLOW (assert-phase6-ran.rb doctrine), it is not RED.
  def visual_degradation
    parity = @artifact_docs[File.join(@workdir, 'parity-final.json')]
    return nil unless parity.is_a?(Hash)
    verdict = fold(parity['visual_verdict'])
    return nil unless %w[divergent not-executable].include?(verdict)
    # Divergent mirrors DegradationLedger#fidelity_residuals exactly (so
    # verify-complete's report['degradations'] == derived equality holds);
    # not-executable is not ledger-derived, so its reason is the recorded notes.
    notes = parity['visual_notes']
    notes = notes.to_s.strip.empty? ? "blind visual verdict #{verdict} recorded in parity-final.json" : notes.to_s
    notes = 'recorded source-vs-target visual gaps ship in the render' if verdict == 'divergent'
    { 'class' => 'fidelity-residual', 'item' => "visual verdict: #{verdict}",
      'reason' => notes, 'source_artifact' => 'parity-final.json' }
  end

  def document_degradations
    entries = degradation_entries
    visual = visual_degradation
    ledger_absent = @artifact_docs[File.join(@workdir, 'degradation-ledger.json')].nil?
    if visual && ledger_absent && entries.none? { |entry| entry['item'] == visual['item'] }
      entries += [visual]
    end
    entries
  end

  def degradation_entries
    doc = @artifact_docs[File.join(@workdir, 'degradation-ledger.json')]
    Array(doc.is_a?(Hash) ? doc['entries'] : nil).select { |entry| entry.is_a?(Hash) }
  end

  # Recorded, never degradations: Sigma cannot render these as the source does
  # (refs/sigma-platform-differences.json). They never change the verdict.
  def platform_difference_entries
    return [] unless defined?(DegradationLedger) && DegradationLedger.respond_to?(:platform_differences)
    DegradationLedger.platform_differences(@workdir)
  end

  def append_platform_differences(lines, entries)
    return if entries.nil? || entries.empty?
    lines << ''
    lines << '## Platform differences'
    lines << ''
    lines << 'Recorded, not degradations: Sigma renders these differently from the source and a build cannot change it. They do not affect the verdict.'
    lines << ''
    entries.each do |entry|
      lines << "- **#{md(entry['catalog_id'])}** — #{md(entry['item'])}"
    end
  end

  # Minor polish notes: minor gaps a PASSING v2 blind grade recorded. Listed,
  # never degradations — they do not affect the verdict (TJ 2026-11-09).
  def polish_note_entries
    return [] unless defined?(DegradationLedger) && DegradationLedger.respond_to?(:polish_notes)
    # A ledger written before the polish rule still lists these minors as
    # degradations; never show one gap in both sections (re-run the gate).
    listed = degradation_entries.map { |e| e['item'] }
    DegradationLedger.polish_notes(@workdir).reject { |n| listed.include?("visual residual (minor): #{n['item']}") }
  end

  def append_polish_notes(lines, entries)
    return if entries.nil? || entries.empty?
    lines << ''
    lines << '## Minor polish notes'
    lines << ''
    lines << 'Not degradations: the blind visual grade passed, and these minor differences are optional polish. They do not affect the verdict.'
    lines << ''
    entries.each do |entry|
      dim = entry['dimension'].to_s.empty? ? '' : " [#{md(entry['dimension'])}]"
      lines << "- #{md(entry['item'])}#{dim}"
    end
  end

  def waiver_entries
    docs = []
    waiver_doc = @artifact_docs[File.join(@workdir, 'waivers.json')]
    docs << waiver_doc unless waiver_doc.nil?
    parity = @artifact_docs[File.join(@workdir, 'parity-final.json')]
    docs << parity['waivers'] if parity.is_a?(Hash) && parity.key?('waivers')
    entries = docs.flat_map do |doc|
      doc = doc['waivers'] if doc.is_a?(Hash) && doc.key?('waivers')
      Array(doc)
    end
    entries.map { |entry| entry.is_a?(Hash) ? entry : { 'reason' => entry.to_s } }
           .uniq { |entry| JSON.generate(entry.sort.to_h) }
           .sort_by { |entry| JSON.generate(entry.sort.to_h) }
  end

  def paths_for_kind(kind)
    @artifacts.select { |artifact| artifact['kind'] == kind && artifact['present'] }
              .map { |artifact| File.expand_path(artifact['path'], @workdir) }
  end

  def artifact_kind(path)
    artifact = @artifacts.find { |item| item['present'] && File.expand_path(item['path'], @workdir) == path }
    artifact && artifact['kind']
  end

  def status_from(record)
    return nil unless record.is_a?(Hash)
    STATUS_KEYS.each do |key|
      status = normalize_status(record[key])
      return status if status
    end
    nil
  end

  def normalize_status(value)
    return nil unless value.is_a?(String) || value.is_a?(Symbol)
    STATUS_ALIASES[fold(value).gsub(%r{[/_\s]+}, '-')]
  end

  def normalized_state(doc)
    %w[status verdict result].each do |key|
      state = fold(doc[key])
      return state unless state.empty?
    end
    nil
  end

  def first_value(hash, keys)
    keys.each do |key|
      value = hash[key]
      return value unless value.nil? || value.to_s.strip.empty?
    end
    nil
  end

  def first_numeric(hash, keys)
    keys.each do |key|
      value = numeric_value(hash, key)
      return value unless value.nil?
    end
    nil
  end

  def numeric_value(hash, key)
    return nil unless hash.key?(key) && numeric?(hash[key])
    integer(hash[key])
  end

  def integer(value)
    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def numeric?(value)
    !Float(value).nil?
  rescue ArgumentError, TypeError
    false
  end

  def boolean?(value)
    value == true || value == false
  end

  def object_key(type, id, name)
    # Case-folded but NOT stripped: "X" and "X " must keep distinct keys.
    identity = id.empty? ? "name:#{name.downcase}" : id.downcase
    "#{fold(type)}:#{identity}"
  end

  def singularize(value)
    word = value.to_s.strip
    return word.sub(/ies\z/i, 'y') if word =~ /ies\z/i
    word.sub(/s\z/i, '')
  end

  def fold(value)
    value.to_s.strip.downcase
  end

  def check(name, status, message)
    { 'name' => name, 'status' => status, 'message' => message }
  end

  def add_generated_at
    return unless ENV.key?('SOURCE_DATE_EPOCH')
    epoch = Integer(ENV['SOURCE_DATE_EPOCH'])
    @document['generated_at'] = Time.at(epoch).utc.iso8601
  rescue ArgumentError
    raise MigrationReportError, 'SOURCE_DATE_EPOCH must be an integer'
  end

  def md(value)
    value.to_s.gsub('|', '\\|').gsub(/\r?\n/, ' ')
  end

  def append_entries(lines, heading, entries)
    return if entries.empty?
    lines << ''
    lines << "## #{heading}"
    lines << ''
    entries.each do |entry|
      item = entry['item'] || entry['flag'] || entry['control'] || entry['name'] || heading.sub(/s\z/, '')
      reason = entry['reason'] || entry['detail'] || entry['evidence'] || 'recorded'
      lines << "- **#{md(item)}** — #{md(reason)}"
    end
  end
end

def parse_options(argv)
  options = {}
  parser = OptionParser.new do |p|
    p.banner = 'Usage: build-migration-report.rb --workdir DIR [options]'
    p.on('--workdir DIR') { |value| options[:workdir] = value }
    p.on('--inventory PATH') { |value| options[:inventory] = value }
    p.on('--markdown PATH') { |value| options[:markdown] = value }
    p.on('--json-out PATH') { |value| options[:json_out] = value }
    p.on('--check') { options[:check] = true }
  end
  parser.parse!(argv)
  raise MigrationReportError, 'missing required --workdir' if options[:workdir].to_s.empty?
  workdir = File.expand_path(options[:workdir])
  raise MigrationReportError, "--workdir is not a directory: #{workdir}" unless File.directory?(workdir)
  options[:workdir] = workdir
  unless options[:inventory]
    name = MigrationReport::INVENTORY_NAMES.find { |candidate| File.file?(File.join(workdir, candidate)) }
    raise MigrationReportError, "no source inventory found (tried #{MigrationReport::INVENTORY_NAMES.join(', ')})" unless name
    options[:inventory] = File.join(workdir, name)
  end
  options[:markdown] ||= File.join(workdir, 'MIGRATION_REPORT.md')
  options[:json_out] ||= File.join(workdir, 'migration-result.json')
  options
rescue OptionParser::ParseError => e
  raise MigrationReportError, e.message
end

def write_atomic(path, content)
  dir = File.dirname(File.expand_path(path))
  raise MigrationReportError, "output directory does not exist: #{dir}" unless File.directory?(dir)
  temporary = "#{path}.tmp.#{$$}"
  # Binary mode is required for byte-stable `--check` output on Windows.
  # Text-mode File.write expands LF to CRLF there, while the in-memory expected
  # string remains LF-only, making an immediately generated report look stale.
  File.binwrite(temporary, content)
  File.rename(temporary, path)
ensure
  File.delete(temporary) if defined?(temporary) && File.exist?(temporary)
end

begin
  options = parse_options(ARGV)
  report = MigrationReport.new(options[:workdir], options[:inventory])
  document = report.build
  json = JSON.pretty_generate(document) + "\n"
  markdown = report.markdown

  if options[:check]
    stale = []
    json_current = begin
      JSON.parse(File.read(options[:json_out])) if File.file?(options[:json_out])
    rescue JSON::ParserError
      nil
    end
    stale << options[:json_out] unless json_current == document

    markdown_current = File.file?(options[:markdown]) ? File.binread(options[:markdown]) : nil
    markdown_current = markdown_current.gsub(/\r\n?/, "\n") if markdown_current
    stale << options[:markdown] unless markdown_current == markdown
    unless stale.empty?
      warn "migration report check failed; stale or missing output(s): #{stale.join(', ')}"
      exit 1
    end
  else
    write_atomic(options[:json_out], json)
    write_atomic(options[:markdown], markdown)
    puts "migration report: #{document['verdict']} " \
         "(#{document.dig('summary', 'accounted')}/#{document.dig('summary', 'total')} accounted)"
  end
  exit(document['verdict'] == 'RED' ? 1 : 0)
rescue MigrationReportError => e
  warn "build-migration-report: #{e.message}"
  exit 2
rescue SystemCallError => e
  warn "build-migration-report: #{e.message}"
  exit 2
end
