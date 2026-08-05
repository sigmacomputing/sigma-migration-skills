#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-learned-rules.rb — regression test for the learned-rules loader:
#
#   1. The repo-shipped starter pack (learned/starter-rules.yaml) parses,
#      loads, and carries only validated rules with the fields agents rely on.
#   2. Merge semantics: starter pack loads even with NO user file (fresh
#      machine); user rules OVERRIDE starter rules on key collision
#      (feature + tableau_pattern); user rules are consulted FIRST by
#      apply()'s first-match-wins.
#   3. Spec-guidance rules (no tableau_pattern/sigma_template) are never
#      auto-applied — apply() skips them.
#   4. append() writes to the USER file only (starter pack is read-only).
#
#   ruby scripts/test-learned-rules.rb

require 'tmpdir'
require 'yaml'

$failures = 0
def ok(cond, msg)
  puts(cond ? "  ok - #{msg}" : "  FAIL - #{msg}")
  $failures += 1 unless cond
end

HERE = __dir__
REAL_STARTER = File.expand_path('../learned/starter-rules.yaml', HERE)

Dir.mktmpdir('t2s-learned-rules') do |tmp|
  home = File.join(tmp, 'home')
  Dir.mkdir(home)
  ENV['TABLEAU_TO_SIGMA_HOME'] = home

  require_relative 'learned-rules'

  puts 'real starter pack (shipped at the skill root):'
  ok(File.exist?(REAL_STARTER), 'learned/starter-rules.yaml exists at the skill root')
  starter_doc = YAML.safe_load(File.read(REAL_STARTER))
  ok(starter_doc.is_a?(Hash) && starter_doc['rules'].is_a?(Array) && starter_doc['rules'].any?,
     'starter pack parses and carries rules')
  starter_doc['rules'].each do |r|
    ok(r['feature'].to_s != '' && r['description'].to_s != '' && r['confidence'] == 'validated',
       "starter rule #{r['feature'].inspect}: feature + description + confidence=validated")
  end

  puts 'load: starter pack alone (fresh machine, no user file):'
  rules = LearnedRules.load
  ok(rules.length == starter_doc['rules'].length,
     "fresh machine loads all #{starter_doc['rules'].length} starter rules (got #{rules.length})")
  ok(rules.all? { |r| r['origin'] == 'starter' }, 'all rules tagged origin=starter')

  puts 'apply: spec-guidance rules (no pattern/template) never rewrite:'
  %w[SUM([Sales]) IIF([flag],1,0) "Q"&DATEPART('quarter',[d])].each do |f|
    t, = LearnedRules.apply(rules, f)
    ok(t.nil?, "no starter rewrite fires on #{f.inspect}")
  end

  puts 'merge: user rules override starter rules on key collision:'
  # Craft a temp starter with one rewrite rule + one guidance rule, and a
  # user file that (a) collides on key, (b) adds a new rule.
  tmp_starter = File.join(tmp, 'starter.yaml')
  File.write(tmp_starter, {
    'rules' => [
      { 'feature' => 'FINDNTH_EMAIL', 'tableau_pattern' => 'FINDNTH',
        'sigma_template' => 'STARTER_TEMPLATE', 'confidence' => 'validated' },
      { 'feature' => 'GUIDANCE_ONLY', 'description' => 'spec note', 'confidence' => 'validated' },
      { 'feature' => 'PROPOSED_SKIPPED', 'tableau_pattern' => 'XYZ',
        'sigma_template' => 'NOPE', 'confidence' => 'proposed' }
    ]
  }.to_yaml)
  File.write(File.join(home, 'learned-rules.yaml'), {
    'rules' => [
      { 'feature' => 'FINDNTH_EMAIL', 'tableau_pattern' => 'FINDNTH',
        'sigma_template' => 'USER_TEMPLATE', 'confidence' => 'validated' },
      { 'feature' => 'USER_EXTRA', 'tableau_pattern' => 'MYFUNC',
        'sigma_template' => 'UserFunc()', 'confidence' => 'validated' }
    ]
  }.to_yaml)
  ENV['TABLEAU_TO_SIGMA_STARTER_RULES'] = tmp_starter
  merged = LearnedRules.load
  ok(merged.length == 3, "collided starter rule dropped, guidance kept (got #{merged.length}, want 3)")
  ok(merged.none? { |r| r['sigma_template'] == 'STARTER_TEMPLATE' }, 'user rule replaced the collided starter rule')
  ok(merged.none? { |r| r['feature'] == 'PROPOSED_SKIPPED' }, 'non-validated starter rules are not loaded')
  ok(merged.first['origin'] == 'user', 'user rules come first (first-match-wins precedence)')
  t, hint = LearnedRules.apply(merged, 'FINDNTH([Email], ".", 2)')
  ok(t&.include?('USER_TEMPLATE'), "apply() uses the USER template on collision (got #{t.inspect})")
  ok(hint.to_s.include?('FINDNTH_EMAIL'), 'hint names the rule')
  t2, = LearnedRules.apply(merged, 'MYFUNC([x])')
  ok(t2&.include?('UserFunc()'), 'non-colliding user rule still applies')

  puts 'append: writes the USER file only:'
  LearnedRules.append('feature' => 'APPENDED', 'tableau_pattern' => 'AP',
                      'sigma_template' => 'Ap()', 'confidence' => 'validated')
  user_doc = YAML.safe_load(File.read(File.join(home, 'learned-rules.yaml')))
  ok(user_doc['rules'].any? { |r| r['feature'] == 'APPENDED' }, 'append landed in the user file')
  ok(!File.read(tmp_starter).include?('APPENDED'), 'starter pack untouched by append')

  puts 'load: unreadable user file degrades to starter-only (no crash):'
  File.write(File.join(home, 'learned-rules.yaml'), ": : :\n\t- bogus")
  degraded = LearnedRules.load
  ok(degraded.length == 2 && degraded.all? { |r| r['origin'] == 'starter' },
     'bogus user yaml skipped with a warning; starter rules still load')

  ENV.delete('TABLEAU_TO_SIGMA_STARTER_RULES')
  ENV.delete('TABLEAU_TO_SIGMA_HOME')
end

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
