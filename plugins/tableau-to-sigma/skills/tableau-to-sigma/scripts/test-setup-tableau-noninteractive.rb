#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for setup-tableau.rb's non-interactive secrets path (v5.6
# item 5).
#
# Field crash (Windows Git-Bash): IO#noecho raises Errno::EBADF when stdin is
# not a real TTY, which crashed the script mid-prompt — and the ad-hoc recovery
# echoed the PAT secret into the transcript. setup-tableau.rb now:
#   (a) with no TTY, reads everything from the documented env vars
#       (TABLEAU_SERVER_URL / TABLEAU_SITE_CONTENT_URL / TABLEAU_PAT_NAME /
#       TABLEAU_PAT_SECRET) — or exits 2 naming them; it NEVER echo-prompts;
#   (b) --from-env forces the same path explicitly;
#   (c) prints where each value was sourced from, never the secret itself.
#
# Hermetic: HOME is a tmpdir, stdin is a pipe (never a TTY under IO.popen) —
# the stdin-closed simulation the item calls for.
#
# Usage: ruby scripts/test-setup-tableau-noninteractive.rb

require 'json'
require 'tmpdir'

DIR   = __dir__
SETUP = File.join(DIR, 'setup-tableau.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

TAB_VARS = %w[TABLEAU_SERVER_URL TABLEAU_SITE_CONTENT_URL TABLEAU_PAT_NAME TABLEAU_PAT_SECRET].freeze

def run_setup(home, args, timeout: 15, env: {})
  out = +''
  base_env = { 'HOME' => home }
  TAB_VARS.each { |v| base_env[v] = nil } # hermetic: runner env must not leak
  io = IO.popen(base_env.merge(env), ['ruby', SETUP] + args, err: %i[child out])
  pid = io.pid
  t = Thread.new { out << io.read.to_s }
  hung = t.join(timeout).nil?
  if hung
    Process.kill('KILL', pid) rescue nil
    t.join(2)
  end
  io.close rescue nil
  [$?&.exitstatus, out.force_encoding('UTF-8').scrub('?'), hung]
end

SECRET = 'pat-supersecret-abcdef-987654'

Dir.mktmpdir do |home|
  # (1) no TTY + no env vars => exit 2 fast, names the env vars + --from-env,
  # writes nothing, never echo-prompts for the secret.
  code, out, hung = run_setup(home, [])
  check(!hung, 'no-TTY path does not hang (stdin-closed simulation)', fails)
  check(code == 2, "no-TTY without env vars exits 2 (got #{code})", fails)
  check(TAB_VARS.all? { |v| out.include?(v) }, 'refusal names every documented env var', fails)
  check(out.include?('--from-env'), 'refusal names the --from-env flag', fails)
  check(out.include?('NEVER read via an echoing prompt') || out.include?('never echoed'),
        'refusal states the no-echo rule', fails)
  check(!File.exist?(File.join(home, '.sigma-migration', 'env')),
        'nothing written on the refusal path', fails)
end

Dir.mktmpdir do |home|
  # (2) no TTY + env vars => proceeds from env; sources printed; secret hidden.
  code, out, hung = run_setup(home, [], env: {
                                'TABLEAU_SERVER_URL' => 'https://tableau.example.test/',
                                'TABLEAU_SITE_CONTENT_URL' => 'mysite',
                                'TABLEAU_PAT_NAME' => 'ci-pat',
                                'TABLEAU_PAT_SECRET' => SECRET
                              })
  check(!hung && code == 0, "no-TTY with env vars exits 0 (got #{code})", fails)
  check(out.include?('env TABLEAU_PAT_SECRET'), 'output says the secret came from the env var', fails)
  check(!out.include?(SECRET), 'the secret is never echoed to the output', fails)
  neutral = File.join(home, '.sigma-migration', 'env')
  check(File.exist?(neutral), 'neutral env file written', fails)
  body = File.read(neutral)
  check(body.include?("export TABLEAU_PAT_SECRET='#{SECRET}'") &&
        body.include?("export TABLEAU_SERVER_URL='https://tableau.example.test'"),
        'neutral file carries the env-sourced values (trailing slash trimmed)', fails)
  check((File.stat(neutral).mode & 0o777) == 0o600, 'neutral file is 0600', fails)
  sj = JSON.parse(File.read(File.join(home, '.claude', 'settings.json')))
  check(sj.dig('env', 'TABLEAU_PAT_NAME') == 'ci-pat' &&
        sj.dig('env', 'TABLEAU_PAT_SECRET') == SECRET,
        'settings.json env block carries the creds', fails)
end

Dir.mktmpdir do |home|
  # (3) --from-env with an EMPTY site contentUrl is valid (Default site).
  code, out, = run_setup(home, ['--from-env'], env: {
                           'TABLEAU_SERVER_URL' => 'https://tableau.example.test',
                           'TABLEAU_PAT_NAME' => 'ci-pat',
                           'TABLEAU_PAT_SECRET' => SECRET
                         })
  check(code == 0, "--from-env with blank site exits 0 — Default site (got #{code})", fails)
  check(out.include?('Default site'), 'blank contentUrl reported as the Default site', fails)
end

Dir.mktmpdir do |home|
  # (4) --from-env missing the secret => exit 2, names what is missing.
  code, out, = run_setup(home, ['--from-env'], env: {
                           'TABLEAU_SERVER_URL' => 'https://tableau.example.test',
                           'TABLEAU_PAT_NAME' => 'ci-pat'
                         })
  check(code == 2, "--from-env without the secret exits 2 (got #{code})", fails)
  check(out.include?('TABLEAU_PAT_SECRET'), 'failure names the missing secret env var', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — setup-tableau non-interactive secrets path'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
