#!/usr/bin/env ruby
# Load + apply learned translation rules from TWO sources, merged:
#
#   1. The repo-shipped STARTER PACK (learned/starter-rules.yaml at the skill
#      root) — transferable rules validated on real migration runs, shipped
#      with the skill so no machine starts empty.
#   2. The customer's accumulated rules in their HOME directory
#      (~/.tableau-to-sigma/learned-rules.yaml), NOT in the skill repo — so
#      `git pull` of the skill never clobbers what a customer has discovered
#      locally, and one customer's wins persist across every workbook they
#      migrate.
#
# Merge semantics: the starter pack loads first, then the user file; USER
# rules OVERRIDE starter rules on key collision (feature + tableau_pattern)
# and are consulted first by apply()'s first-match-wins. append() writes only
# to the user file — the starter pack is read-only skill content.
#
# User file location is canonical: ~/.tableau-to-sigma/learned-rules.yaml
# Override for testing via TABLEAU_TO_SIGMA_HOME env var (user home) and
# TABLEAU_TO_SIGMA_STARTER_RULES (starter-pack path).
#
# Schema (YAML):
#   rules:
#     - feature: "FINDNTH_EMAIL"
#       description: "customer-specific FINDNTH wrapper → array composition"
#       tableau_pattern: '\bFINDNTH\s*\(\s*\[Email\]\s*,\s*"\."\s*,\s*2\s*\)'
#       sigma_template: 'Len(ArrayJoin(ArraySlice(SplitToArray([Master/Email], "."), 0, 2), ".")) + 1'
#       hint: "validated against this customer's warehouse"
#       validated_at: "2026-05-19T16:42:00Z"
#       validated_workbook: "wb-id-here"
#       example_from: "workbook.twb line 1234"
#       confidence: "validated" | "proposed" | "experimental"
#
# Entries MAY omit tableau_pattern/sigma_template — those are SPEC-GUIDANCE
# rules (spec shapes / Sigma-formula authoring rules that are not safe blind
# regex rewrites). apply() skips them (it requires both fields); they surface
# via the CLI dump below and refs/fidelity-recipes.md. The repo starter pack
# (learned/starter-rules.yaml) uses this flavor heavily.
#
# ⚠ SHADOWING: learned rules run BEFORE the built-in translators in
# build-charts-from-signals.rb. The WINDOW_* / RUNNING_* / RANK / LOOKUP /
# INDEX / TOTAL table-calc family is now BUILT-IN (WINPROBE-validated mapping,
# refs/window-functions.md) — do NOT add learned rules for those functions
# unless deliberately overriding for one customer; a stale rule (e.g. an old
# `MovingAvg(Sum(x), -10, 10)` template — that arg shape is WRONG, Sigma
# Moving* takes positive back/forward counts) silently shadows the correct
# built-in translation.
#
# Usage from the build script:
#   require_relative 'learned-rules'
#   rules = LearnedRules.load
#   translated, hint = LearnedRules.apply(rules, formula)

require 'yaml'
require 'date'
require 'time'

module LearnedRules
  HOME_OVERRIDE = ENV['TABLEAU_TO_SIGMA_HOME']
  DEFAULT_HOME  = File.expand_path('~/.tableau-to-sigma')
  # Repo-shipped starter pack lives at the SKILL ROOT (learned/), sibling of
  # scripts/. Env override exists for tests only.
  DEFAULT_STARTER = File.expand_path('../learned/starter-rules.yaml', __dir__)

  def self.home
    HOME_OVERRIDE || DEFAULT_HOME
  end

  def self.rules_path
    File.join(home, 'learned-rules.yaml')
  end

  def self.starter_path
    ENV['TABLEAU_TO_SIGMA_STARTER_RULES'] || DEFAULT_STARTER
  end

  def self.escalations_dir
    File.join(home, 'escalations')
  end

  def self.ensure_home
    Dir.mkdir(home) unless Dir.exist?(home)
    Dir.mkdir(escalations_dir) unless Dir.exist?(escalations_dir)
  end

  # Load rules: repo starter pack first, then the customer's accumulated
  # rules. USER rules override starter rules on key collision
  # (feature + tableau_pattern) and come FIRST in the returned array so
  # apply()'s first-match-wins consults them before any starter rule.
  # Returns [] when neither file exists — normal first-time case, NOT an
  # error (a fresh checkout still gets the starter pack).
  def self.load
    starter = load_file(starter_path, 'starter')
    user    = load_file(rules_path,   'user')
    user_keys = user.map { |r| rule_key(r) }
    user + starter.reject { |r| user_keys.include?(rule_key(r)) }
  end

  # Identity used for user-overrides-starter dedupe — the same identity
  # append() dedupes on.
  def self.rule_key(rule)
    [rule['feature'], rule['tableau_pattern']]
  end

  # Load one rules file. Returns [] if the file is missing. Tags each rule
  # with its 'origin' (starter|user) for the CLI dump / debugging; consumers
  # that only read feature/pattern/template are unaffected.
  def self.load_file(path, origin)
    return [] unless File.exist?(path)
    data = YAML.safe_load(File.read(path), permitted_classes: [Time, Date]) || {}
    rules = (data['rules'] || []).select do |r|
      # Only apply confidence=validated rules by default. proposed/experimental
      # rules are loaded but flagged so the agent can dry-run before trusting.
      conf = r['confidence'] || 'validated'
      conf == 'validated'
    end
    rules.each { |r| r['origin'] ||= origin }
    rules
  rescue StandardError => e
    warn "WARN  learned-rules yaml at #{path} unreadable: #{e.message}; skipping"
    []
  end

  # Apply rules to a formula. Returns [translated_formula, hint] when a rule
  # matched, [nil, nil] when none did. First matching rule wins so customers
  # can override built-in rules by adding a more-specific pattern earlier.
  def self.apply(rules, formula)
    return [nil, nil] if formula.nil? || formula.empty?
    rules.each do |r|
      pat = r['tableau_pattern']
      tmpl = r['sigma_template']
      next if pat.nil? || tmpl.nil?
      begin
        re = Regexp.new(pat)
      rescue RegexpError
        next
      end
      next unless formula =~ re
      translated = formula.gsub(re, tmpl)
      next if translated == formula
      hint_parts = []
      hint_parts << "learned-rule:#{r['feature']}"
      hint_parts << r['hint'] if r['hint']
      hint_parts << "(confidence=#{r['confidence']})" if r['confidence'] && r['confidence'] != 'validated'
      return [translated, hint_parts.join(' — ')]
    end
    [nil, nil]
  end

  # Append a freshly-validated rule to the customer's file. Called by the
  # gap-scout subagent after a successful Sigma POST + column-type guard.
  def self.append(rule)
    ensure_home
    existing = if File.exist?(rules_path)
                 YAML.safe_load(File.read(rules_path), permitted_classes: [Time, Date]) || {}
               else
                 {}
               end
    existing['rules'] ||= []
    # Deduplicate by feature+pattern
    existing['rules'].reject! { |r| r['feature'] == rule['feature'] && r['tableau_pattern'] == rule['tableau_pattern'] }
    existing['rules'] << rule
    File.write(rules_path, existing.to_yaml)
    rules_path
  end

  # Save a structured escalation for a gap the scout couldn't solve. Filed
  # locally — Phase 4 will mirror to GitHub/beads via `gh issue create` or
  # `bd create`.
  def self.escalate(payload)
    ensure_home
    slug = (payload['feature'] || 'unknown').downcase.gsub(/\W+/, '-')[0..40].sub(/-$/, '')
    path = File.join(escalations_dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{slug}.yaml")
    File.write(path, payload.to_yaml)
    path
  end
end

# CLI: when invoked directly, dump the loaded rules for debugging
if $PROGRAM_NAME == __FILE__
  rules = LearnedRules.load
  puts "Starter-pack file:  #{LearnedRules.starter_path}#{File.exist?(LearnedRules.starter_path) ? '' : '  (missing)'}"
  puts "User rules file:    #{LearnedRules.rules_path}#{File.exist?(LearnedRules.rules_path) ? '' : '  (missing — normal first-time case)'}"
  puts "  rules loaded:      #{rules.length}"
  rules.each_with_index do |r, i|
    puts "  [#{i}] #{r['feature']} (#{r['confidence'] || 'validated'}, #{r['origin'] || 'user'})"
    if r['tableau_pattern'] && r['sigma_template']
      puts "      pattern: #{r['tableau_pattern']}"
      puts "      → #{r['sigma_template']}"
    else
      puts "      [spec-guidance — not auto-applied] #{r['description'].to_s.strip.gsub(/\s+/, ' ')[0..140]}"
      puts "      hint: #{r['hint'].to_s.strip.gsub(/\s+/, ' ')[0..140]}" if r['hint']
    end
  end
end
