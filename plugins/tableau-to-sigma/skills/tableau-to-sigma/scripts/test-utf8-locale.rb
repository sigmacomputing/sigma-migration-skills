#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test: lib/utf8_locale.rb makes spawned children inherit a UTF-8 locale
# even when the parent was started with LANG/LC_ALL unset (finalize US-ASCII crash).
require 'open3'
require 'rbconfig'
require_relative 'lib/utf8_locale'
$fails = 0
def ok(c, m)
  puts "  #{c ? 'PASS' : 'FAIL'}  #{m}"
  $fails += 1 unless c
end
U = Utf8Locale

ok(U.pick(%w[POSIX en_US.utf8]) == 'en_US.UTF-8', 'pick(): loose utf8 spelling matches')
ok(U.pick(%w[C.UTF-8 en_US.UTF-8]) == 'C.UTF-8', 'pick(): C.UTF-8 preferred')
ok(U.pick(%w[POSIX C]).nil?, 'pick(): none installed → nil')
e = { 'LANG' => 'en_US.UTF-8' }
ok(U.ensure!(e, available: []) == :already && e['LC_ALL'].nil?, 'already UTF-8 → untouched')
e = { 'LC_ALL' => 'C', 'LANG' => 'en_US.UTF-8' }
ok(U.ensure!(e, available: %w[en_US.UTF-8]) == 'en_US.UTF-8' && e['LC_ALL'] == 'en_US.UTF-8', 'LC_ALL=C overrides a UTF-8 LANG → fixed')
e = {}
ok(U.ensure!(e, available: %w[C.UTF-8]) == 'C.UTF-8' && e['LANG'] == 'C.UTF-8' && e['PYTHONUTF8'] == '1', 'unset → LANG+LC_ALL+PYTHONUTF8 set')

if U.pick(U.installed_locales)
  lib = File.join(__dir__, 'lib', 'utf8_locale.rb')
  child = "puts Encoding.default_external"
  parent = "require #{lib.inspect}; Utf8Locale.ensure!; puts Open3.capture2(RbConfig.ruby, '-e', #{child.inspect}).first"
  clean = ENV.to_h.reject { |k, _| %w[LANG LC_ALL LC_CTYPE].include?(k) }
  base, = Open3.capture2(clean, RbConfig.ruby, '-e', child, unsetenv_others: true)
  out, = Open3.capture2(clean, RbConfig.ruby, '-ropen3', '-rrbconfig', '-e', parent, unsetenv_others: true)
  ok(out.strip == 'UTF-8', "grandchild spawned with LANG unset reports UTF-8 (got #{out.strip.inspect}; unfixed control: #{base.strip})")
else
  puts '  SKIP  no UTF-8 locale installed on this host'
end
ok(File.read(File.join(__dir__, 'migrate-tableau.rb')).include?('Utf8Locale.ensure!'), 'migrate-tableau.rb calls Utf8Locale.ensure! early')

puts $fails.zero? ? 'ALL PASS' : "#{$fails} FAILED"
exit($fails.zero? ? 0 : 1)
