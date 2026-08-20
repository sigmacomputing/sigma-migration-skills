#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-skill-paths.rb — ban marketplace-unsafe / stale path advice in skills.
#
# Agents (esp. non-Claude) follow paths in SKILL.md / refs/ literally. Two
# classes of advice break outside a historical sibling checkout:
#
#   1. Legacy `sigma-skills/…` or `~/sigma-skills/…` (sibling repo upstream of
#      sigma-authoring — runners of *this* marketplace never have that tree).
#   2. Deep repo-relative links from a skill into `docs/` (e.g.
#      `](../../../../docs/phase-schema.md)`), which 404 when the skill is
#      installed alone as a Claude Code marketplace plugin.
#
# `plugins/sigma-authoring/**` is skipped: those skills are vendored from
# upstream `sigmacomputing/sigma-skills` (see plugins/sigma-authoring/SYNC.md) and
# may still mention the upstream tree until re-vendored.
#
#   ruby tools/lint-skill-paths.rb
#
# Creds-free, stdlib-only — safe for governance hooks / CI.

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# [id, human description, regex]
RULES = [
  [
    'legacy-sigma-skills-path',
    'stale sigma-skills/ path — use companion sigma-authoring / sigma-workbooks instead',
    %r{(?:~/sigma-skills|(?<![/\w-])sigma-skills/sigma-)}
  ],
  [
    'marketplace-unsafe-docs-relative',
    'deep ../../../../docs/ relative from a skill — breaks marketplace install; name docs/… for full-clone only',
    %r{\]\(\.\./\.\./\.\./\.\./docs/}
  ],
  [
    'broken-sigma-authoring-relative',
    'wrong relative ../sigma-authoring from a skill dir (that path does not exist); use ../../../sigma-authoring/… or skill name',
    # Ban a single-hop `../sigma-authoring/` but allow `../../../sigma-authoring/`
    # (lookbehind rejects when the hop is itself preceded by `./` from a prior `../`).
    %r{(?<!\./)\.\./sigma-authoring/}
  ]
].freeze

# Historical provenance blurbs that name the old staging *repo* (not a runtime path).
ALLOW_FILE_SUBSTRINGS = [
  'sigma-skills-staging', # github.com/…/sigma-skills-staging provenance
  'plugins/sigma-authoring/SYNC.md'
].freeze

def skip_path?(rel)
  return true if rel.start_with?('plugins/sigma-authoring/')
  return true if rel.include?('/generated/')
  false
end

hits = [] # [file, line, rule_id, desc, snippet]

Dir.glob('plugins/*/skills/**/*.{md,mdc,rb,py,sh,mjs,js}').sort.each do |path|
  next if skip_path?(path)
  next unless File.file?(path)

  File.readlines(path, chomp: true).each_with_index do |line, idx|
    next if ALLOW_FILE_SUBSTRINGS.any? { |s| line.include?(s) }

    RULES.each do |rid, desc, pat|
      next unless line.match?(pat)
      snippet = line.strip
      snippet = "#{snippet[0, 117]}…" if snippet.length > 120
      hits << [path, idx + 1, rid, desc, snippet]
    end
  end
end

# Also scan the new-skill scaffolder so it cannot reintroduce banned links.
scaffold = 'tools/new-skill.rb'
if File.file?(scaffold)
  File.readlines(scaffold, chomp: true).each_with_index do |line, idx|
    RULES.each do |rid, desc, pat|
      next unless line.match?(pat)
      snippet = line.strip
      snippet = "#{snippet[0, 117]}…" if snippet.length > 120
      hits << [scaffold, idx + 1, rid, desc, snippet]
    end
  end
end

if hits.empty?
  puts "OK: skill path lint clean (#{RULES.size} rules)."
  exit 0
end

puts 'SKILL PATH LINT FAILED — marketplace-unsafe or stale path advice:'
hits.each do |file, line, rid, desc, snippet|
  puts "  FAIL  #{file}:#{line}  [#{rid}] #{desc}"
  puts "        #{snippet}"
end
puts
puts "failures: #{hits.size}. Fix the prose (see docs/agent-entry.md §Path rules),"
puts 'or if this is intentional provenance naming the old staging *repo*, keep'
puts 'the github.com/…/sigma-skills-staging form (already allowlisted per-line).'
exit 1
