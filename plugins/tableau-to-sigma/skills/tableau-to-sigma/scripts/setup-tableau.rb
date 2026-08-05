#!/usr/bin/env ruby
# Store Tableau credentials so any coding agent can load them:
#   - ~/.claude/settings.json   — Claude Code auto-loads this into the env
#   - ~/.sigma-migration/env    — neutral, sourceable file every other agent uses
# Use this when the Tableau MCP isn't available (or when the workbook has an embedded
# datasource that the MCP can't see). See refs/tableau-rest.md.
#
# THREE ways in:
#   * interactive (a real TTY): prompts for each value (secret hidden), OR
#   * --from-env: read every value from the environment, no prompts:
#       TABLEAU_SERVER_URL, TABLEAU_SITE_CONTENT_URL (may be empty = Default
#       site), TABLEAU_PAT_NAME, TABLEAU_PAT_SECRET
#   * no TTY (agent harness / piped run / Windows Git-Bash mintty): behaves
#     like --from-env automatically; if the env vars are missing it prints the
#     exact env-var names and exits 2 — it NEVER falls back to an echoing
#     prompt for the secret.
#
# WINDOWS GIT-BASH FIELD CRASH (2026-07): IO#noecho raises Errno::EBADF when
# stdin isn't a real TTY (mintty pipes it), which crashed this script mid-
# prompt — and the retry temptation is an echoing `gets`, which leaks the PAT
# secret into the terminal/transcript. The secret is now read hidden-or-env
# ONLY: if the hidden prompt is impossible, the value must come from
# TABLEAU_PAT_SECRET. Every stored value prints WHERE it was sourced from.

require 'io/console'
require 'json'
require 'fileutils'

SETTINGS_PATH = File.expand_path("~/.claude/settings.json")
NEUTRAL_PATH  = File.expand_path("~/.sigma-migration/env")
DEFAULT_CLOUD = "https://us-west-2b.online.tableau.com"

ENV_VARS = %w[TABLEAU_SERVER_URL TABLEAU_SITE_CONTENT_URL TABLEAU_PAT_NAME TABLEAU_PAT_SECRET].freeze

from_env = ARGV.delete('--from-env') ? true : false
if ARGV.include?('-h') || ARGV.include?('--help')
  puts 'usage: ruby scripts/setup-tableau.rb [--from-env]'
  puts "  interactive (TTY): prompts; PAT secret hidden."
  puts "  --from-env (or no TTY): reads #{ENV_VARS.join(', ')} from the environment."
  exit 0
end

# Upsert `export KEY='value'` lines into the neutral cred file (0600), preserving
# any other vars already there (e.g. Sigma creds from setup.rb).
def upsert_neutral_env(pairs)
  FileUtils.mkdir_p(File.dirname(NEUTRAL_PATH), mode: 0o700)
  body = File.exist?(NEUTRAL_PATH) ? File.read(NEUTRAL_PATH) : ""
  pairs.each do |k, v|
    line = "export #{k}='#{v}'"
    if body =~ /^export #{Regexp.escape(k)}=.*$/
      body = body.sub(/^export #{Regexp.escape(k)}=.*$/, line)
    else
      body += "\n" unless body.empty? || body.end_with?("\n")
      body += line + "\n"
    end
  end
  File.write(NEUTRAL_PATH, body)
  File.chmod(0o600, NEUTRAL_PATH)
end

def env_missing_exit(missing)
  warn 'ERROR: no TTY for the interactive prompts (or --from-env given), and these'
  warn "environment variables are not set: #{missing.join(', ')}"
  warn ''
  warn 'Export them and re-run (values are stored, never echoed):'
  warn "  export TABLEAU_SERVER_URL='https://<pod>.online.tableau.com'   # or your Server URL"
  warn "  export TABLEAU_SITE_CONTENT_URL='<site>'   # blank/unset = Default site"
  warn "  export TABLEAU_PAT_NAME='<pat name>'"
  warn "  export TABLEAU_PAT_SECRET='<pat secret>'"
  warn '  ruby scripts/setup-tableau.rb --from-env'
  warn ''
  warn '…or run this script once from a real terminal (it will prompt; the secret'
  warn 'prompt is hidden). The secret is NEVER read via an echoing prompt.'
  exit 2
end

tty = $stdin.tty?
from_env ||= !tty
sources = {}

puts "Tableau credential setup#{from_env ? ' (non-interactive: values from the environment)' : ''}"
puts "Values are stored in #{SETTINGS_PATH} and loaded automatically into every Claude Code session."
puts

if from_env
  missing = %w[TABLEAU_SERVER_URL TABLEAU_PAT_NAME TABLEAU_PAT_SECRET].select { |k| ENV[k].to_s.empty? }
  env_missing_exit(missing) unless missing.empty?
  server      = ENV['TABLEAU_SERVER_URL'].to_s
  content_url = ENV['TABLEAU_SITE_CONTENT_URL'].to_s # empty = Default site (valid)
  pat_name    = ENV['TABLEAU_PAT_NAME'].to_s
  pat_secret  = ENV['TABLEAU_PAT_SECRET'].to_s
  ENV_VARS.each { |k| sources[k] = "env #{k}" }
  sources['TABLEAU_SITE_CONTENT_URL'] = 'env TABLEAU_SITE_CONTENT_URL (unset = Default site)' if content_url.empty?
else
  print "Deployment — [c]loud or self-hosted [s]erver? [c]: "
  is_server = $stdin.gets.to_s.strip.downcase.start_with?("s")

  if is_server
    print "Server URL (e.g. https://tableau.mycompany.com): "
    server = $stdin.gets.to_s.chomp
  else
    print "Server URL [#{DEFAULT_CLOUD}]: "
    server = $stdin.gets.to_s.chomp
    server = DEFAULT_CLOUD if server.empty?
  end

  if is_server
    print "Site contentUrl (path segment after /site/ in the URL; LEAVE BLANK for the Default site): "
  else
    print "Site contentUrl (the path segment after /site/ in the Tableau URL, e.g. 'mysite'): "
  end
  content_url = $stdin.gets.to_s.chomp

  print "PAT name (the label you typed when creating the token in Tableau): "
  pat_name = $stdin.gets.to_s.chomp

  print "PAT secret (will be hidden): "
  # HIDDEN-OR-ENV ONLY. IO#noecho raises (Errno::EBADF on Windows Git-Bash
  # mintty, Errno::ENOTTY/ENXIO/IOError elsewhere) when stdin is not a real
  # TTY even though tty? said it was. On that failure: use TABLEAU_PAT_SECRET
  # from the environment if present, else exit 2 with instructions — NEVER
  # fall back to an echoing gets (that leaks the secret into the transcript).
  pat_secret = begin
    s = $stdin.noecho(&:gets)
    puts
    sources['TABLEAU_PAT_SECRET'] = 'hidden prompt'
    s.to_s.chomp
  rescue StandardError => e
    puts
    env_sec = ENV['TABLEAU_PAT_SECRET'].to_s
    if env_sec.empty?
      warn "ERROR: hidden prompt unavailable (#{e.class}: #{e.message}) and TABLEAU_PAT_SECRET is not set."
      warn 'Refusing to read the secret via an echoing prompt. Either:'
      warn "  export TABLEAU_PAT_SECRET='<pat secret>'   # then re-run (or use --from-env)"
      warn '  …or run from a real terminal where the hidden prompt works.'
      exit 2
    end
    warn "(hidden prompt unavailable — #{e.class}; using TABLEAU_PAT_SECRET from the environment, value not echoed)"
    sources['TABLEAU_PAT_SECRET'] = "env TABLEAU_PAT_SECRET (hidden prompt unavailable: #{e.class})"
    env_sec
  end
  sources['TABLEAU_SERVER_URL'] ||= 'prompt'
  sources['TABLEAU_SITE_CONTENT_URL'] ||= 'prompt'
  sources['TABLEAU_PAT_NAME'] ||= 'prompt'
end
server = server.sub(%r{/+$}, '')

# contentUrl is intentionally allowed to be empty — that's the Tableau Server
# "Default" site. Everything else is required.
if [server, pat_name, pat_secret].any?(&:empty?)
  abort "Server URL, PAT name, and PAT secret are required. Aborting without writing settings."
end

settings = File.exist?(SETTINGS_PATH) ? JSON.parse(File.read(SETTINGS_PATH)) : {}
settings["env"] ||= {}
settings["env"]["TABLEAU_SERVER_URL"]        = server
settings["env"]["TABLEAU_SITE_CONTENT_URL"]  = content_url
settings["env"]["TABLEAU_PAT_NAME"]          = pat_name
settings["env"]["TABLEAU_PAT_SECRET"]        = pat_secret

FileUtils.mkdir_p(File.dirname(SETTINGS_PATH))
File.write(SETTINGS_PATH, JSON.pretty_generate(settings))

upsert_neutral_env(
  "TABLEAU_SERVER_URL"       => server,
  "TABLEAU_SITE_CONTENT_URL" => content_url,
  "TABLEAU_PAT_NAME"         => pat_name,
  "TABLEAU_PAT_SECRET"       => pat_secret,
)

puts "Wrote Tableau credentials to:"
puts "  #{SETTINGS_PATH}  (Claude Code auto-loads this)"
puts "  #{NEUTRAL_PATH}  (any other agent / shell)"
puts
puts "Where each value came from (secret never echoed):"
puts "  TABLEAU_SERVER_URL:       #{server}  [#{sources['TABLEAU_SERVER_URL'] || 'prompt'}]"
puts "  TABLEAU_SITE_CONTENT_URL: #{content_url.empty? ? '(Default site)' : content_url}  [#{sources['TABLEAU_SITE_CONTENT_URL'] || 'prompt'}]"
puts "  TABLEAU_PAT_NAME:         #{pat_name}  [#{sources['TABLEAU_PAT_NAME'] || 'prompt'}]"
puts "  TABLEAU_PAT_SECRET:       (#{pat_secret.length} chars, hidden)  [#{sources['TABLEAU_PAT_SECRET'] || 'prompt'}]"
puts
puts "Claude Code: open a new session (or `! source ~/.claude/settings.json`)."
puts "Other agents / shell: `source ~/.sigma-migration/env`, then run"
puts "`eval \"$(scripts/get-tableau-token.sh)\"` to sign in."
