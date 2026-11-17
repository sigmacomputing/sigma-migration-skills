# frozen_string_literal: true
# Minimal Lightdash REST client. UNVALIDATED against a real instance: coded
# from the documented OpenAPI (refs/lightdash-source-contract.md, REST API
# section); tests inject a fake transport and never touch the network.
#
#   client = LightdashRest::Client.from_env      # LIGHTDASH_URL + LIGHTDASH_API_KEY
#   client.get('/api/v1/org')                    # unwraps {status:"ok", results: ...}
#   client.post('/api/v1/projects/P/explores/orders/runQuery', metric_query)
#
# Auth header is `Authorization: ApiKey <token>`. The key is never logged and is
# scrubbed from error messages. A transport is any callable
# (method, uri, headers, body_string_or_nil) -> [status_code, body_string].
# Ruby 2.6-compatible, stdlib only.

require 'net/http'
require 'json'
require 'uri'

module LightdashRest
  class Error < StandardError; end

  class Client
    attr_reader :base_url

    def self.from_env(env = ENV, transport: nil)
      url = env['LIGHTDASH_URL'].to_s.strip
      key = env['LIGHTDASH_API_KEY'].to_s.strip
      raise Error, 'LIGHTDASH_URL not set' if url.empty?
      raise Error, 'LIGHTDASH_API_KEY not set' if key.empty?
      new(base_url: url, api_key: key, transport: transport)
    end

    # True when both env vars are present (callers use this to choose live vs offline).
    def self.configured?(env = ENV)
      !env['LIGHTDASH_URL'].to_s.strip.empty? && !env['LIGHTDASH_API_KEY'].to_s.strip.empty?
    end

    def initialize(base_url:, api_key:, transport: nil)
      @base_url = base_url.to_s.sub(%r{/+\z}, '')
      host = (URI(@base_url).host rescue nil).to_s
      if @base_url.start_with?('http://') && !%w[localhost 127.0.0.1 ::1 [::1]].include?(host) && !host.end_with?('.localhost')
        warn "warning: LIGHTDASH_URL is plain http:// to #{host}; the API key is sent unencrypted. Use https://."
      end
      @api_key = api_key.to_s
      @transport = transport || method(:net_http)
    end

    def get(path, query: nil)
      request('GET', path, nil, query)
    end

    def post(path, body = {})
      request('POST', path, body, nil)
    end

    def inspect
      "#<LightdashRest::Client #{@base_url}>"
    end

    private

    def request(verb, path, body, query)
      uri = URI("#{@base_url}#{path.to_s.start_with?('/') ? path : "/#{path}"}")
      uri.query = URI.encode_www_form(query) if query && !query.empty?
      headers = { 'Authorization' => "ApiKey #{@api_key}", 'Accept' => 'application/json' }
      payload = nil
      unless body.nil?
        headers['Content-Type'] = 'application/json'
        payload = body.is_a?(String) ? body : JSON.generate(body)
      end
      code, text = @transport.call(verb, uri, headers, payload)
      handle(verb, path, code.to_i, text.to_s)
    end

    def handle(verb, path, code, text)
      unless code.between?(200, 299)
        raise Error, "#{verb} #{path} -> HTTP #{code}: #{scrub(text)[0, 300]}"
      end
      return {} if text.strip.empty?
      parsed = begin
        JSON.parse(text)
      rescue JSON::ParserError
        raise Error, "#{verb} #{path} -> HTTP #{code} but the body is not JSON: #{scrub(text)[0, 120]}"
      end
      if parsed.is_a?(Hash) && parsed.key?('status') && parsed['status'] != 'ok'
        raise Error, "#{verb} #{path} -> status #{parsed['status'].inspect}: #{scrub(parsed['error'] || parsed).to_s[0, 300]}"
      end
      parsed.is_a?(Hash) && parsed.key?('results') ? parsed['results'] : parsed
    end

    def scrub(text)
      s = text.to_s
      @api_key.empty? ? s : s.gsub(@api_key, '[redacted]')
    end

    def net_http(verb, uri, headers, body)
      req = (verb == 'POST' ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.read_timeout = 120
      res = http.request(req)
      [res.code.to_i, res.body.to_s]
    end
  end
end
