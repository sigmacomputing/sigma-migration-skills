#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-skills.rb — conformance gate for migration skills (bead: skill-governance).
#
# Every converter SKILL.md must document the mandatory arc gates (see
# docs/phase-schema.md). This greps each skill for high-signal evidence of each
# gate and fails the PR if a NEW skill (or an edit) drops one. Known, accepted
# gaps are recorded in tools/skill-lint-baseline.json so they show as tracked
# WARNINGS rather than failures — clear that backlog by fixing the skill and
# removing the baseline entry.
#
# Byte budgets (E9.2/E9.3 context diet) ride the same baseline mechanism —
# NOT a separate allowlist. Three rules over EVERY skill dir (converters,
# assessments, bridges, authoring alike):
#
#   (a) SKILL.md             <= 20480 bytes (20KB) — the every-session pre-read
#   (b) any single refs/*.md <= 32768 bytes (32KB) — phase-scoped refs stay loadable
#   (c) the mandatory pre-read list in SKILL.md names <= 3 refs/ files —
#       progressive disclosure is the contract, not a stanza. Counted inside a
#       <!-- mandatory-pre-read --> … <!-- /mandatory-pre-read --> block when
#       present; otherwise a legacy "Read ALL of the following" block (counted
#       up to the next heading/hr). No block at all = nothing to enforce.
#
# Budget exceptions live in tools/skill-lint-baseline.json under the skill
# dir's basename with rule ids 'skill-md-bytes', 'ref-bytes:<file>.md', and
# 'pre-read-width', each carrying a NON-EMPTY justification — a blank reason
# FAILS the lint (schema pin, both rule families). RATCHET procedure: diet the
# file (relocate detail into phase-scoped refs — tableau-to-sigma is the
# template), then DELETE the entry; never add an entry for a NEW skill — new
# skills start inside budget. Fixture self-test (trip AND no-false-trip):
# tools/test-lint-skills-budgets.sh.
#
#   ruby tools/lint-skills.rb            # lint; non-zero on un-baselined gap
#
# Creds-free, stdlib-only — safe for the corpus-check workflow.

require 'json'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

baseline_path = 'tools/skill-lint-baseline.json'
BASELINE = File.exist?(baseline_path) ? JSON.parse(File.read(baseline_path)) : {}

# E9.2/E9.3 byte budgets (see header). Exceptions ride BASELINE, never a
# separate allowlist.
SKILL_MD_BUDGET = 20_480
REF_MD_BUDGET   = 32_768
PRE_READ_MAX    = 3

# Each rule: id, description, and a regex whose presence in SKILL.md is the
# evidence the gate exists. Patterns are deliberately broad (any documented
# phrasing counts) — the goal is "did the author drop a whole gate", not style.
CONVERTER_RULES = [
  ['reuse-check',     'C3 reuse-check (avoid DM sprawl)',     /find-or-pick|reuse|pick (an?|existing).*(data model|\bdm\b)/i],
  ['post-dm-readback','C5 POST DM + read back real ids',      /read[- ]?back/i],
  ['layout-last',     'C7 layout applied as the LAST write',  /apply-layout|put-layout|layout\.xml|last write|newspaper layout|layout.*(last|after)/i],
  ['parity-gate',     'C8 parity hard gate',                  /parit/i],
  ['security-rls',    'C9 RLS/CLS detection',                 /\bRLS\b|\bCLS\b|row.?level security|column.?level security|security:/i],
]

# Repo-level: the canonical Rosetta stone (docs/phase-schema.md) maps each
# converter's local phase numbers to the C1–C10 arc. Its mapping-table column
# headers are the exact skill dir names, so a converter missing from the doc is
# a converter nobody can cross-reference. New skills MUST be added there.
PHASE_SCHEMA = 'docs/phase-schema.md'

# Skills that are NOT full converters and are exempt from the converter ruleset.
def classify(dir)
  base = File.basename(dir)
  return :assessment if base.end_with?('-assessment')
  return :bridge     if base.end_with?('-to-cdw')   # data-landing, builds no workbook
  return :converter  if base.end_with?('-to-sigma')
  :other
end

skills = Dir.glob('plugins/*/skills/*').select { |d| File.file?("#{d}/SKILL.md") }.sort

fails = []   # [skill, rule_id, desc]
warns = []   # [skill, rule_id, desc, reason]
ok = 0

schema_body = File.exist?(PHASE_SCHEMA) ? File.read(PHASE_SCHEMA) : ''

skills.each do |dir|
  next unless classify(dir) == :converter
  body = File.read("#{dir}/SKILL.md")
  name = File.basename(dir)
  checks = CONVERTER_RULES.map { |id, desc, pat| [id, desc, body.match?(pat)] }
  # repo-level coverage check folded in per-skill so it reports against the skill
  checks << ['phase-schema-coverage', 'listed in docs/phase-schema.md mapping', schema_body.include?(name)]
  checks.each do |id, desc, present|
    next if present
    reason = BASELINE.dig(name, id)
    if reason
      warns << [name, id, desc, reason]
    else
      fails << [name, id, desc]
    end
  end
  ok += 1
end

# ---------------------------------------------------------------------------
# Byte budgets (E9.2/E9.3 context diet) — every skill dir, all classes. See
# header for rules + the baseline ratchet. Baselined entries WARN; blank
# justifications FAIL (schema pin, enforced for BOTH rule families below).
# ---------------------------------------------------------------------------
budget_fails = []  # [skill, msg]
budget_warns = []  # [skill, msg, reason]

BASELINE.each do |skill, rules|
  next unless rules.is_a?(Hash) # '_comment' is a String
  rules.each do |rid, why|
    next unless why.to_s.strip.empty?
    budget_fails << [skill, "baseline entry '#{rid}' has an EMPTY justification — every exception carries a reason"]
  end
end

# The refs the mandatory pre-read block cites, or nil when the skill declares
# no such block (nothing to enforce). Outside-the-block citations never count.
def pre_read_refs(text)
  m = text.match(%r{<!--\s*mandatory-pre-read\s*-->(.*?)<!--\s*/mandatory-pre-read\s*-->}m)
  block = m && m[1]
  unless block
    # Legacy fat-block signature: "Read ALL of the following" up to the next
    # heading or horizontal rule.
    m = text.match(/Read ALL of the following.*?(?=\n\#{1,6} |\n---\n|\z)/m)
    return nil unless m
    block = m[0]
  end
  block.scan(%r{refs/[A-Za-z0-9_.\-]+\.md}).uniq.sort
end

# Baselined (with any reason, blank already failed above) => WARN, not FAIL.
budget_check = lambda do |name, rid, msg|
  reason = BASELINE.dig(name, rid)
  if reason
    budget_warns << [name, msg, reason.to_s]
  else
    budget_fails << [name, "#{msg} — diet the file into phase-scoped refs/, or baseline '#{rid}' with a justification"]
  end
end

skills.each do |dir|
  name = File.basename(dir)
  skill_md = "#{dir}/SKILL.md"
  size = File.size(skill_md)
  if size > SKILL_MD_BUDGET
    budget_check.call(name, 'skill-md-bytes',
                      "#{skill_md}: #{size} bytes > #{SKILL_MD_BUDGET} (SKILL.md budget)")
  end
  Dir.glob("#{dir}/refs/*.md").sort.each do |ref|
    rsize = File.size(ref)
    next unless rsize > REF_MD_BUDGET
    budget_check.call(name, "ref-bytes:#{File.basename(ref)}",
                      "#{ref}: #{rsize} bytes > #{REF_MD_BUDGET} (per-ref budget)")
  end
  refs = pre_read_refs(File.read(skill_md, encoding: 'UTF-8'))
  next unless refs && refs.size > PRE_READ_MAX
  budget_check.call(name, 'pre-read-width',
                    "#{skill_md}: mandatory pre-read names #{refs.size} refs > #{PRE_READ_MAX} " \
                    "(#{refs.first(5).join(', ')}#{refs.size > 5 ? '…' : ''})")
end

# ---------------------------------------------------------------------------
# Portability content-lint (bead: windows-portability). The rules above check
# SKILL.md prose; these scan SCRIPT BODIES for the class of "validated only on
# macOS" footgun that shipped in #346 — a bug that is LATENT on the BSD/macOS
# dev box and only bites on Windows/Linux. A regression here fails the PR.
# ---------------------------------------------------------------------------
port_fails = []  # [path, lineno, msg]

# #346: a shell `base64` ENCODE must strip newlines. GNU coreutils base64 (Git
# Bash on Windows, Linux CI) wraps at 76 columns, injecting newlines that
# corrupt a multi-line Authorization header; BSD/macOS base64 does not wrap, so
# the bug is invisible on the dev box. Require `tr -d '\n'` (portable) or
# `-w0`/`--wrap=0` (GNU-only) on the same pipeline.
Dir.glob('**/*.sh').sort.each do |f|
  File.readlines(f).each_with_index do |line, i|
    next if line =~ /\A\s*#/                           # skip comments
    next unless line =~ /\|\s*base64\b/                # pipes INTO base64 (encode)
    next if line =~ /base64\s+(-d|-D|--decode)\b/       # decode, not encode
    next if line =~ /tr\s+-d/ || line =~ /base64\s+(-w\s*0|--wrap[= ]?0)/
    port_fails << [f, i + 1,
                   "shell base64 encode without newline strip — add `| tr -d '\\n'` " \
                   '(GNU base64 wraps at 76 cols and corrupts the auth header; see #346)']
  end
end

unless warns.empty?
  puts "Tracked baseline gaps (WARN — fix and remove from #{baseline_path}):"
  warns.each { |n, id, desc, r| puts "  ~ #{n}: #{desc}\n      #{r}" }
  puts
end

unless budget_warns.empty?
  puts "Tracked byte-budget exceptions (WARN — diet the file, then remove from #{baseline_path}):"
  budget_warns.each { |n, msg, r| puts "  ~ #{n}: #{msg}\n      #{r}" }
  puts
end

if fails.empty? && budget_fails.empty? && port_fails.empty?
  puts "OK: #{ok} converter SKILL.md files document all mandatory gates " \
       "(#{warns.size} tracked baseline gaps); byte budgets clean " \
       "(SKILL.md<=#{SKILL_MD_BUDGET}B, refs/*.md<=#{REF_MD_BUDGET}B, " \
       "pre-read<=#{PRE_READ_MAX} files; #{budget_warns.size} tracked exceptions); " \
       'portability content-lint clean.'
  exit 0
end

unless fails.empty?
  puts "SKILL CONFORMANCE FAILURE"
  puts "A converter SKILL.md is missing a mandatory gate (docs/phase-schema.md)."
  puts "Fix the skill, or — if genuinely N/A — add it to #{baseline_path} with a reason."
  puts
  fails.each { |n, id, desc| puts "  FAIL  #{n}: missing #{id} — #{desc}" }
  puts
  puts "conformance failures: #{fails.size}"
  puts
end

unless budget_fails.empty?
  puts 'BYTE-BUDGET LINT FAILED — doc surface over its byte budget (E9.2/E9.3):'
  budget_fails.each { |n, msg| puts "  FAIL  #{n}: #{msg}" }
  puts
  puts "budget failures: #{budget_fails.size}  (budgets: SKILL.md<=#{SKILL_MD_BUDGET}B, " \
       "refs/*.md<=#{REF_MD_BUDGET}B, pre-read<=#{PRE_READ_MAX} files; exceptions: #{baseline_path})"
  puts
end

unless port_fails.empty?
  puts "PORTABILITY LINT FAILURE"
  puts "A script has a known cross-platform footgun (latent on macOS; breaks on Windows/Linux)."
  puts
  port_fails.each { |f, ln, msg| puts "  FAIL  #{f}:#{ln} — #{msg}" }
  puts
  puts "portability failures: #{port_fails.size}"
end
exit 1
