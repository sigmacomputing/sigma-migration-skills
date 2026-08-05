#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the off-ramp observability trail (2026-07-09).
#
# Every point where a run leaves the golden path (cred waiver, PASS-1 stop,
# converter-stop, workbook-handoff, degraded fast path, manual-spec) appends a
# structured record to <WORK>/offramps.jsonl, and verify-complete.rb surfaces the
# trail under its verdict. This proves the logger appends + reads back, is never
# fatal, and that verify-complete prints the trail. Offline.
#
# Usage: ruby scripts/test-offramp.rb

require 'json'
require 'tmpdir'

DIR = __dir__
require_relative 'lib/offramp'
VC = File.join(DIR, 'verify-complete.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

Dir.mktmpdir do |wd|
  # append two off-ramps
  Offramp.log(wd, kind: 'pass1-stop', detail: 'workbook wb-1')
  Offramp.log(wd, kind: 'cred-gate-waived', reason: 'offline-test')
  trail = Offramp.trail(wd)
  check(trail.size == 2, "trail has both records (got #{trail.size})", fails)
  check(trail[0]['kind'] == 'pass1-stop' && trail[1]['reason'] == 'offline-test', 'records preserve kind/reason', fails)
  check(trail.all? { |r| r['at'] =~ /\d{4}-\d\d-\d\dT/ }, 'each record carries a timestamp', fails)

  # never fatal on a bad workdir
  begin
    Offramp.log('/no/such/dir/really', kind: 'x')
    check(true, 'logging to a missing dir does not raise', fails)
  rescue StandardError => e
    check(false, "logging to a missing dir raised: #{e.class}", fails)
  end
  check(Offramp.trail('/no/such/dir').empty?, 'trail of a missing dir is empty', fails)

  # verify-complete surfaces the trail under a NOT-DONE verdict
  File.write(File.join(wd, 'parity-pending.json'), JSON.generate('workbookId' => 'wb-1', 'stage' => 'pass1'))
  out = IO.popen(['ruby', VC, '--workdir', wd], err: %i[child out], &:read)
  check(out.include?('off-ramps taken this run'), 'verify-complete prints the off-ramp trail header', fails)
  check(out.include?('pass1-stop') && out.include?('cred-gate-waived'), 'trail lists the recorded off-ramps', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
