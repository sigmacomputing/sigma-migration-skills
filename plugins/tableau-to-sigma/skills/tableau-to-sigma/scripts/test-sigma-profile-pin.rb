#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for lib/sigma_profile_pin.rb: the plugin-local twin of the shared
# "explicit SIGMA_CLI_PROFILE pins the org" rule, used by migrate-tableau.rb's
# credential gate to decide whether it may refill the settings file's org keys.
#
# Usage: ruby scripts/test-sigma-profile-pin.rb
require 'tmpdir'
require 'fileutils'
require_relative 'lib/sigma_profile_pin'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

SETTINGS = <<~ENVFILE
  export SIGMA_BASE_URL='https://org-a.example.com'
  export SIGMA_CLIENT_ID='org-a-id'
  export SIGMA_CLIENT_SECRET='org-a-secret'
  export SIGMA_CLI_PROFILE='file-profile'
  export SNOWFLAKE_ACCOUNT='acct-a'
ENVFILE

Dir.mktmpdir do |home|
  dir = File.join(home, '.sigma-migration')
  FileUtils.mkdir_p(dir)
  path = File.join(dir, 'env')
  File.write(path, SETTINGS)
  pin = ->(env) { SigmaProfilePin.pinned?(env, path) }

  check(pin.call('SIGMA_CLI_PROFILE' => 'work (1)'), 'explicit profile pins', fails)
  check(!pin.call({}), 'no profile: not pinned (settings refill allowed)', fails)
  check(!pin.call('SIGMA_CLI_PROFILE' => '  '), 'blank profile: not pinned', fails)
  check(!pin.call('SIGMA_CLI_PROFILE' => 'file-profile'),
        "profile equal to the file's own: not pinned", fails)
  check(!pin.call('SIGMA_CLI_PROFILE' => 'work (1)', 'SIGMA_CLI_PROFILE_FROM_FILE' => 'work (1)'),
        'profile equal to SIGMA_CLI_PROFILE_FROM_FILE: not pinned', fails)
  check(pin.call('SIGMA_CLI_PROFILE' => 'Work (1)', 'SIGMA_CLI_PROFILE_FROM_FILE' => 'work (1)'),
        'case differs from the marker: pinned', fails)
  check(pin.call('SIGMA_CLI_PROFILE' => 'File-Profile'),
        "case differs from the file's own: pinned", fails)
  check(SigmaProfilePin.settings_file_profile(path) == 'file-profile',
        'reads only the file SIGMA_CLI_PROFILE, quotes stripped', fails)
  File.write(path, "SIGMA_CLI_PROFILE=a\nexport SIGMA_CLI_PROFILE=\"b\"\n")
  check(SigmaProfilePin.settings_file_profile(path) == 'b', 'last assignment wins', fails)
  check(SigmaProfilePin.settings_file_profile(File.join(dir, 'missing')) == '', 'missing file => empty', fails)
  check(pin.call('SIGMA_CLI_PROFILE' => 'a'), 'earlier assignment is not the file profile: pinned', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
