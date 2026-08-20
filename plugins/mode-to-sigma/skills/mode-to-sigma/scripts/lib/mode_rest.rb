# Basic-Auth REST client for the Mode Analytics API (app.mode.com).
# Every request re-sends Basic Auth (token:secret) — Mode has no refreshable
# bearer token, unlike Sigma/Domo, so there is no token-staleness machinery here.
require 'net/http'
require 'json'
require 'uri'

module Mode
  HOST = 'app.mode.com'

  class Error < StandardError; end

  module_function

  def account
    ENV.fetch('MODE_ACCOUNT') { raise Error, 'MODE_ACCOUNT not set' }
  end

  def token
    ENV.fetch('MODE_API_TOKEN') { raise Error, 'MODE_API_TOKEN not set' }
  end

  def secret
    ENV.fetch('MODE_API_SECRET') { raise Error, 'MODE_API_SECRET not set' }
  end

  def http
    h = Net::HTTP.new(HOST, 443)
    h.use_ssl = true
    h.read_timeout = 120
    h
  end

  # Builds a request URI from `path` — which may already carry its own query
  # string, as HAL `_links[...].href` values commonly do (pagination, filtered
  # results) — plus an optional extra `query` Hash/Array to merge in.
  #
  # Parsing the full "https://HOST+path" string with URI() (rather than
  # URI::HTTPS.build's separate host:/path:/query: components) matters: if
  # `path` already contains a literal "?", URI::HTTPS.build raises
  # URI::InvalidComponentError — NOT Mode::Error — which breaks the documented
  # contract that callers only need to rescue Mode::Error.
  def build_uri(path, query = nil)
    uri = URI("https://#{HOST}#{path}")
    if query
      extra = URI.encode_www_form(query)
      uri.query = uri.query ? "#{uri.query}&#{extra}" : extra
    end
    uri
  end

  # Parses `Retry-After` into a delay in seconds (default 2s), used by each
  # caller below right before its single retry on a 429 -- never inside
  # handle() itself (see handle()'s own comment: sleeping there would sleep
  # out the delay even on an already-exhausted retry, achieving nothing).
  # RFC 7231 also permits an HTTP-date form for Retry-After (not just
  # delay-seconds), and a header could in principle be malformed — `Integer()`
  # raises ArgumentError (bad string) or TypeError (nil header) in those cases,
  # so fall back to the 2s default rather than blowing up.
  def retry_after_seconds(res)
    Integer(res['Retry-After'])
  rescue ArgumentError, TypeError
    2
  end

  def get(path, query: nil, _retried: false)
    uri = build_uri(path, query)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    req['Accept'] = 'application/json'
    res = http.request(req)
    handle(res)
  rescue Error
    # `res &&`: a pre-request error (e.g. `token`/`secret` raising Mode::Error
    # for a missing credential, inside req.basic_auth above) leaves `res` nil
    # — without this guard, `res.code` raises NoMethodError on nil, burying
    # the original clear credential-error message under a confusing crash.
    raise unless res && res.code.to_i == 429 && !_retried
    sleep(retry_after_seconds(res))
    get(path, query: query, _retried: true)
  end

  # GET without JSON parsing, for CSV/binary responses. Routed through the
  # same handle()-based 429/backoff handling as get/post (rather than its own
  # inline 2xx check) so rate limiting is treated consistently everywhere.
  def get_raw(path, _retried: false)
    uri = build_uri(path)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(token, secret)
    res = http.request(req)
    handle(res, parse: false)
  rescue Error
    raise unless res && res.code.to_i == 429 && !_retried
    sleep(retry_after_seconds(res))
    get_raw(path, _retried: true)
  end

  def post(path, body:, _retried: false)
    uri = build_uri(path)
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(token, secret)
    req['Content-Type'] = 'application/json'
    req['Accept'] = 'application/json'
    req.body = body.to_json
    res = http.request(req)
    handle(res)
  rescue Error
    raise unless res && res.code.to_i == 429 && !_retried
    sleep(retry_after_seconds(res))
    post(path, body: body, _retried: true)
  end

  # Follows a HAL `_links[rel].href` on a previously-fetched resource.
  def follow(resource, rel)
    link = resource.dig('_links', rel)
    raise Error, "resource has no _links.#{rel}" unless link
    get(link['href'])
  end

  # `parse: false` returns the raw body string (for get_raw) instead of
  # JSON-parsing it — mirrors domo_rest.rb's handle(res, accept) split for
  # its CSV-export path.
  #
  # Deliberately does NOT sleep on a 429 here (previously did) — every caller
  # (get/get_raw/post) only retries once, so sleeping inside handle() slept
  # out the FULL Retry-After delay even on the second attempt's failure (the
  # one that will NOT be retried — the caller's `!_retried` guard re-raises
  # instead), achieving nothing but a pointless wait. The sleep now happens in
  # each caller's rescue clause, gated on the same condition that decides
  # whether a retry will actually happen.
  def handle(res, parse: true)
    code = res.code.to_i
    raise Error, "#{res.code}: #{res.body}" unless code.between?(200, 299)
    return (parse ? {} : '') if res.body.nil? || res.body.empty?
    parse ? JSON.parse(res.body) : res.body
  end
end
