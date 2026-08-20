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
end
