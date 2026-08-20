#!/usr/bin/env ruby
# frozen_string_literal: true
#
# register-plugin.rb — idempotent Sigma custom-plugin registration helper
# (WS2 "plugin-recreation" Task 4).
#
# Extracts the inline register/confirm dance already proven live in
# `verify-plugin-gauge-e2e.rb` (Task 1 — see `plugins_by_name` /
# `register_plugin` there) into a reusable module + CLI, so other
# scripts/skills that need to register a Sigma plugin don't have to
# re-derive the masked-404-tolerant confirmation logic.
#
# PluginRegister.register_or_get(name:, description:, url:, dev_url:) is
# IDEMPOTENT:
#   1. GET /v2/plugins first — if a plugin with this exact `name` already
#      exists, return its pluginId. Never creates a duplicate.
#   2. Else POST /v2/plugins {name,description,url,devUrl,type:"element"},
#      then re-GET /v2/plugins and find by name. A non-2xx POST is NEVER
#      treated as a hard failure by itself — Sigma is documented to
#      sometimes return a masked 404 (or other error) on an otherwise-
#      successful register, so the confirming GET is always attempted
#      before deciding.
#      `devUrl` is a real, schema-documented optional request property (see
#      plugin-lifecycle.md §1 — this is a Beta, lightly-documented API, not
#      in either public split OpenAPI spec). The API defaults it to
#      `http://localhost:5173` if omitted; this helper sends it explicitly
#      (same default) so dev-mode registration states its intent rather than
#      relying on an implicit server-side default. Pass `dev_url: nil` to
#      omit the `devUrl` key entirely and fall back to the API's own default
#      instead of this helper's.
#      `type: 'element'` is STILL sent even though the same schema lookup
#      shows it documented as response-only there (always "element",
#      never a request field): the body INCLUDING `type` is the one proven
#      live against a real Sigma org (see this file's own header — WS2 v1,
#      gauge archetype). Whether an undocumented extra field is silently
#      accepted or rejected was never live-tested (declined, to avoid
#      creating a real plugin record just to check) — so dropping it would
#      trade a known-working body for an unverified one, over a field most
#      REST APIs tolerate silently when present but undocumented. Kept
#      until someone gets a chance to confirm live that it's truly a no-op.
#   3. Only if, after POST+GET, the plugin still isn't found AND the POST
#      response clearly indicated an auth/permission failure (401/403) does
#      this raise PluginRegister::PermissionError: "plugin registration is
#      permission-gated (org-admin) — <detail>". Any other unresolved case
#      raises a plain error (never a faked pluginId).
#
# Usage (library):
#   $LOAD_PATH.unshift File.expand_path('../scripts', __dir__)  # adjust as needed
#   require 'register-plugin'
#   plugin_id = PluginRegister.register_or_get(
#     name: "My Plugin", description: "...", url: "https://example.com/plugin/",
#     dev_url: "http://localhost:5173"  # optional — this is the default
#   )
#
# Usage (CLI):
#   ruby shared/scripts/register-plugin.rb "<name>" "<url>" ["<description>"] ["<devUrl>"]
#   -> prints the pluginId to stdout on success (exit 0); on failure, prints
#      an error to stderr and exits non-zero. `<devUrl>` defaults to
#      `http://localhost:5173` (the API's own default) if omitted.
#
# Env: SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (or
#      ~/.sigma-migration/env — sigma_rest.rb self-bootstraps).
#
# Cross-reference: shared/scripts/verify-plugin-gauge-e2e.rb (WS2 Task 1) is
# the origin of this logic and the live-proven reference implementation;
# consumers should prefer this helper over re-inlining the same dance.

require 'json'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'sigma_rest'

module PluginRegister
  # Raised only when a POST /v2/plugins failure is unambiguously an auth/
  # permission problem (401/403) AND the confirming GET also came up empty.
  class PermissionError < StandardError; end

  module_function

  # Look up a plugin by exact `name` via GET /v2/plugins. Returns the plugin
  # Hash (with at least a 'pluginId' or 'id' key) or nil if none matches.
  def find_by_name(name)
    list = Sigma.request(:get, '/v2/plugins?pageSize=1000')
    list = (JSON.parse(list) rescue nil) if list.is_a?(String)
    entries = (list.is_a?(Hash) && (list['entries'] || list['plugins'])) || []
    entries.find { |p| p['name'] == name }
  end

  # Idempotent register-or-get. Returns the pluginId (String). Raises
  # PermissionError on a confirmed 401/403 with no plugin found afterward, or
  # a plain RuntimeError for any other unresolved failure.
  #
  # `dev_url:` defaults to the API's own default (`http://localhost:5173`)
  # and is sent explicitly rather than relying on that implicit default.
  # Pass `dev_url: nil` to omit the `devUrl` key from the request body
  # entirely (`.compact` below drops any nil value, `devUrl` included).
  # `type: 'element'` is always sent — see the module comment above for why
  # it's kept despite the request schema documenting it as response-only.
  def register_or_get(name:, description:, url:, dev_url: 'http://localhost:5173')
    existing = find_by_name(name)
    existing_id = existing && (existing['pluginId'] || existing['id'])
    return existing_id if existing_id

    post_error = nil
    body = { name: name, description: description, url: url, devUrl: dev_url, type: 'element' }.compact
    begin
      Sigma.request(:post, '/v2/plugins', body: JSON.generate(body))
    rescue Sigma::Error => e
      # Never trust the POST's own status — the masked-404 quirk means even a
      # successful register can raise here. Always fall through to the
      # confirming GET below before deciding anything.
      post_error = e
    end

    plugin = find_by_name(name)
    plugin_id = plugin && (plugin['pluginId'] || plugin['id'])
    return plugin_id if plugin_id

    if post_error && post_error.message =~ /-> (401|403)\b/
      raise PermissionError,
            "plugin registration is permission-gated (org-admin) — #{post_error.message[0, 300]}"
    end

    raise "plugin registration failed: could not confirm pluginId for #{name.inspect} via " \
          "GET /v2/plugins after POST#{post_error ? " (POST raised: #{post_error.message[0, 300]})" : ' (POST returned 2xx)'}"
  end
end

if $PROGRAM_NAME == __FILE__
  name        = ARGV[0]
  url         = ARGV[1]
  description = ARGV[2] || ''
  dev_url     = ARGV[3].to_s.empty? ? 'http://localhost:5173' : ARGV[3]

  if name.nil? || url.nil?
    warn 'Usage: ruby register-plugin.rb "<name>" "<url>" ["<description>"] ["<devUrl>"]'
    exit 2
  end

  begin
    plugin_id = PluginRegister.register_or_get(name: name, description: description, url: url, dev_url: dev_url)
    puts plugin_id
  rescue PluginRegister::PermissionError => e
    warn e.message
    exit 1
  rescue StandardError => e
    warn "register-plugin failed: #{e.message}"
    exit 1
  end
end
