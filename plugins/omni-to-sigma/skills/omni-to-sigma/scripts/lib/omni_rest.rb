# frozen_string_literal: true
# Bearer-Auth REST client for the Omni Analytics API (<org>.omniapp.co).
# Supports rate-limit Retry-After backoff on 429 and JSON / raw responses.

require 'net/http'
require 'json'
require 'uri'

module OmniRest
  class Error < StandardError; end

  module_function

  def base_url
    raw = ENV.fetch('OMNI_BASE_URL') { raise Error, 'OMNI_BASE_URL not set' }.to_s.strip
    raise Error, 'OMNI_BASE_URL is empty' if raw.empty?
    raw.end_with?('/') ? raw.chomp('/') : raw
  end

  def token
    tok = ENV.fetch('OMNI_API_TOKEN') { raise Error, 'OMNI_API_TOKEN not set' }.to_s.strip
    raise Error, 'OMNI_API_TOKEN is empty' if tok.empty?
    tok
  end

  def build_uri(path, query = nil)
    rel = path.to_s.start_with?('/') ? path.to_s : "/#{path}"
    uri = URI("#{base_url}#{rel}")
    if query && !query.empty?
      extra = URI.encode_www_form(query)
      uri.query = uri.query ? "#{uri.query}&#{extra}" : extra
    end
    uri
  end

  def http_for(uri)
    h = Net::HTTP.new(uri.host, uri.port)
    h.use_ssl = (uri.scheme == 'https')
    h.read_timeout = 120
    h
  end

  def retry_after_seconds(res)
    Integer(res['Retry-After'])
  rescue ArgumentError, TypeError
    2
  end

  def get(path, query: nil, _retried: false)
    uri = build_uri(path, query)
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Accept'] = 'application/json'
    res = http_for(uri).request(req)
    handle(res)
  rescue Error
    raise unless res && res.code.to_i == 429 && !_retried
    sleep(retry_after_seconds(res))
    get(path, query: query, _retried: true)
  end

  def post(path, body:, _retried: false)
    uri = build_uri(path)
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    res = http_for(uri).request(req)
    handle(res)
  rescue Error
    raise unless res && res.code.to_i == 429 && !_retried
    sleep(retry_after_seconds(res))
    post(path, body: body, _retried: true)
  end

  def handle(res, parse: true)
    code = res.code.to_i
    raise Error, "#{res.code}: #{res.body}" unless code.between?(200, 299)
    return (parse ? {} : '') if res.body.nil? || res.body.empty?
    parse ? JSON.parse(res.body) : res.body
  end
end
