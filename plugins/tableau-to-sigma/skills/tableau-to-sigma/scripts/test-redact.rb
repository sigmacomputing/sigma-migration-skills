#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the credential-masking lib (PR-2 field-ops, secrets hygiene).
#
# Contract (refs/operating-contract.md "Credential hygiene"): never echo
# credential values — Redact.mask keeps only the last 4 chars, Redact.scrub
# masks any sensitive-env-var VALUE (…SECRET/…TOKEN/…_PAT_…/…PASSWORD) found in
# free text, and PATH-like vars are never touched. Fixture values are assembled
# at runtime so no credential-shaped literal is committed. Offline.
#
# Usage: ruby scripts/test-redact.rb

DIR = __dir__
require_relative 'lib/redact'
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# ── mask ─────────────────────────────────────────────────────────────────────
check(Redact.mask('abcdefgh1234') == '****1234', 'mask keeps only the last 4 chars', fails)
check(Redact.mask('abcd') == '****', 'a <=4-char value masks entirely', fails)
check(Redact.mask('ab') == '****', 'a tiny value masks entirely', fails)
check(Redact.mask('') == '(unset)', 'empty value reads (unset)', fails)
check(Redact.mask(nil) == '(unset)', 'nil value reads (unset)', fails)
long = 'zz' * 30 + 'tail'
check(Redact.mask(long) == '****tail' && !Redact.mask(long).include?('zz'),
      'long values never leak their body', fails)

# ── scrub ────────────────────────────────────────────────────────────────────
# Fixture secrets built at runtime (never committed as credential-shaped literals).
secret = %w[qq ww ee rr tt yy].join + '9876'
token  = 'tok' + '4321abcd' * 3
patval = 'pat' + 'value' + '5555'
ENV['TEST_SCRUB_SECRET']  = secret
ENV['TEST_SCRUB_TOKEN']   = token
ENV['TEST_PAT_VALUE']     = patval          # _PAT_ segment => sensitive
ENV['TEST_SCRUB_PATHISH'] = '/usr/local/some-dir' # PATH-like name => NOT sensitive
ENV['TEST_TINY_TOKEN']    = 'abc'           # <6 chars => skipped (collision-prone)

text = "creds: #{secret} then #{token}, pat #{patval}, dir /usr/local/some-dir, abc end"
scrubbed = Redact.scrub(text)
check(!scrubbed.include?(secret), 'scrub masks a *_SECRET value', fails)
check(!scrubbed.include?(token), 'scrub masks a *_TOKEN value', fails)
check(!scrubbed.include?(patval), 'scrub masks a *_PAT_* value', fails)
check(scrubbed.include?("****#{secret[-4..-1]}"), 'masked value keeps its last 4 chars', fails)
check(scrubbed.include?('/usr/local/some-dir'), 'PATH-like var values are left alone', fails)
check(scrubbed.include?('abc end'), 'tiny (<6 char) values are not substituted', fails)
check(Redact.scrub('no secrets here') == 'no secrets here', 'text without secrets is unchanged', fails)

# PATH itself must never be treated as sensitive (the PAT false-positive trap).
check(Redact::SENSITIVE_ENV !~ 'PATH' && Redact::SENSITIVE_ENV !~ 'CLASSPATH',
      'PATH/CLASSPATH names are not sensitive', fails)
check((Redact::SENSITIVE_ENV =~ 'TABLEAU_PAT_SECRET') && (Redact::SENSITIVE_ENV =~ 'TABLEAU_PAT_NAME') &&
      (Redact::SENSITIVE_ENV =~ 'SIGMA_CLIENT_SECRET') && (Redact::SENSITIVE_ENV =~ 'SIGMA_API_TOKEN'),
      'the real credential var names ARE sensitive', fails)

# ── setup.rb applies it (the creds echo path) ────────────────────────────────
setup_src = File.read(File.join(DIR, 'setup.rb'))
check(setup_src.include?('Redact.mask'), 'setup.rb masks the secret via Redact.mask', fails)

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
