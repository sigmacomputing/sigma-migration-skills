# frozen_string_literal: true

require 'json'
require 'uri'

# Idempotent lifecycle client for Sigma data-model element materialization
# schedules (Beta). Kept Power-BI-local until another converter adopts the same
# create/list/patch contract; shared infrastructure changes require a separate PR.
module MaterializationSchedules
  module_function

  def validate!(cron:, timezone: nil)
    raise ArgumentError, 'materialization cron must contain exactly 5 fields' unless cron.to_s.split(/\s+/).size == 5
    valid_timezone = timezone.to_s.empty? || timezone == 'UTC' ||
                     timezone.match?(%r{\A[A-Za-z_+-]+(?:/[A-Za-z0-9_+.-]+)+\z})
    unless valid_timezone
      raise ArgumentError, "materialization timezone must be an IANA name (got #{timezone.inspect})"
    end
  end

  def default_request(method, path, payload = nil)
    require_relative 'sigma_rest'
    Sigma.request(method, path, body: payload && JSON.generate(payload))
  end

  def list(data_model_id, request: method(:default_request), page_size: 500)
    entries = []
    token = nil
    seen = {}
    loop do
      path = "/v2/dataModels/#{data_model_id}/materializationSchedules?pageSize=#{page_size}"
      path += "&pageToken=#{URI.encode_www_form_component(token)}" if token
      body = request.call(:get, path, nil)
      break unless body.is_a?(Hash)

      entries.concat(body['entries'] || [])
      token = body['nextPageToken']
      break if token.to_s.empty?
      raise "materialization schedule list repeated pageToken #{token.inspect}" if seen[token]

      seen[token] = true
    end
    entries
  end

  def reconcile(data_model_id:, elements:, cron:, timezone: nil, request: method(:default_request))
    validate!(cron: cron, timezone: timezone)
    existing = list(data_model_id, request: request).each_with_object({}) do |entry, memo|
      memo[entry['elementId']] = entry
    end
    desired_schedule = { 'cronSpec' => cron }
    desired_schedule['timezone'] = timezone unless timezone.to_s.empty?

    elements.map do |element|
      element_id = element.fetch('id')
      element_name = element['name'] || element_id
      current = existing[element_id]
      current_schedule = current && current['schedule']
      action = {
        'elementId' => element_id,
        'elementName' => element_name,
        'requestedSchedule' => desired_schedule
      }
      begin
        if current.nil?
          response = request.call(
            :post,
            "/v2/dataModels/#{data_model_id}/elements/#{element_id}/materializationSchedules",
            { 'schedule' => desired_schedule }
          )
          action.merge!('status' => 'created', 'schedule' => response && response['schedule'])
        elsif current_schedule == desired_schedule ||
              (timezone.to_s.empty? && current_schedule&.fetch('cronSpec', nil) == cron)
          action.merge!('status' => 'unchanged', 'schedule' => current_schedule)
        else
          response = request.call(
            :patch,
            "/v2/dataModels/#{data_model_id}/elements/#{element_id}/materializationSchedules",
            { 'schedule' => desired_schedule }
          )
          action.merge!('status' => 'updated', 'schedule' => response && response['schedule'])
        end
      rescue StandardError => e
        message = e.message.to_s
        hint =
          if message.match?(/403|not.?permitted|permission/i)
            'API owner needs the Schedule materializations permission'
          elsif message.match?(/write access|writeback|write-back/i)
            'enable write access on the element connection'
          elsif message.match?(/404|not found|beta|entitlement/i)
            'confirm the organization is entitled to the materialization schedule Beta'
          else
            'review the Sigma API error and element materialization eligibility'
          end
        action.merge!('status' => 'error', 'error' => message[0, 500], 'remediation' => hint)
      end
      action
    end
  end

  # Elements a schedule run should cover. Default mode: Custom SQL elements only (`all-sql` or no list;
  # an explicit list names Custom SQL elements). With `targets` (pbi model shape, R21) the default is those
  # element names (summaries, flattened children, Custom SQL fact sources) and an explicit list may name any
  # element kind. `all-sql` still means every Custom SQL element. Returns [[[spec, server], ...], [error action, ...]].
  def select_elements(spec_elements, paired, selectors:, targets: nil)
    all = []
    spec_elements.each_with_index do |element, index|
      server = paired[index]
      next unless server
      all << [element, { 'id' => server['id'], 'name' => server['name'] || element['name'] || element['id'] }]
    end
    sql = all.select { |element, _| element.dig('source', 'kind') == 'sql' }
    pool = targets ? all : sql
    selected =
      if selectors.empty?
        targets ? all.select { |element, _| targets.include?(element['name'].to_s) } : sql
      elsif selectors == ['all-sql']
        sql
      else
        pool.select { |element, server| selectors.include?(element['name'].to_s) || selectors.include?(server['name'].to_s) }
      end
    missing = selectors.reject do |selector|
      selector == 'all-sql' || pool.any? { |element, server| selector == element['name'].to_s || selector == server['name'].to_s }
    end
    actions = missing.map do |selector|
      {
        'elementName' => selector,
        'status' => 'error',
        'error' => "requested materialization element was not found among #{targets ? 'data model' : 'Custom SQL'} elements",
        'remediation' => targets ? 'use an exact element name or all-sql' : 'use an exact Custom SQL element name or all-sql'
      }
    end
    [selected, actions]
  end

  # Materialize one element now (P10): POST :materialize {sheetId}, then poll the materialization until it is
  # ready, skipped (a warehouse-table element has nothing to build) or failed. A schedule's own first run holds
  # the data model busy, so HTTP 409 "already in progress" is retried (one probe run waited about 707 s) until
  # `cap_seconds`. Returns {'status' => ready|skipped|failed|timeout|error, 'states' => [...], 'seconds' => n}.
  # `sheet_id` is the schedule entry's sheetId (defaults to the element id); `sleep` is a callable taking seconds.
  def run_now(data_model_id:, element_id:, request: method(:default_request), sleep: Kernel.method(:sleep),
              cap_seconds: 1200, poll_seconds: 10, sheet_id: nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    waited = 0.0
    states = []
    elapsed = lambda do
      [Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, waited].max
    end
    pause = lambda do
      sleep.call(poll_seconds)
      waited += poll_seconds
    end
    result = lambda do |status, extra = {}|
      { 'status' => status, 'states' => states, 'seconds' => elapsed.call.round(1) }.merge(extra)
    end
    mid = nil
    loop do
      begin
        response = request.call(:post, "/v2/dataModels/#{data_model_id}:materialize", { 'sheetId' => sheet_id || element_id })
        mid = response.is_a?(Hash) ? response['materializationId'] : nil
        return result.call('error', 'error' => 'materialize returned no materializationId') if mid.to_s.empty?
        break
      rescue StandardError => e
        return result.call('error', 'error' => e.message.to_s[0, 300]) unless e.message.to_s =~ /(?:->|status|HTTP|code)\s*:?\s*409\b/i
        states << 'conflict' unless states.last == 'conflict'
        return result.call('timeout', 'error' => "materialize still answering 409 after #{cap_seconds}s") if elapsed.call >= cap_seconds
        pause.call
      end
    end
    loop do
      begin
        body = request.call(:get, "/v2/dataModels/#{data_model_id}/materializations/#{mid}", nil)
      rescue StandardError => e
        return result.call('error', 'error' => e.message.to_s[0, 300])
      end
      state = (body.is_a?(Hash) ? (body['status'] || body['state']) : nil).to_s.downcase
      states << state unless state.empty? || states.last == state
      return result.call(state, 'materializationId' => mid) if %w[ready skipped].include?(state)
      return result.call('failed', 'materializationId' => mid, 'error' => body['error'].to_s[0, 300]) if state =~ /fail|error|cancel/
      return result.call('timeout', 'materializationId' => mid, 'error' => "not ready after #{cap_seconds}s") if elapsed.call >= cap_seconds
      pause.call
    end
  end
end
