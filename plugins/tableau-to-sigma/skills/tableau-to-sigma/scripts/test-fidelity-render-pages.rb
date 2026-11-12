#!/usr/bin/env ruby
# frozen_string_literal: true

# Live re-proof regression: `fidelity-loop.rb render --page-id <id>` ignored
# the page (always rendered the ledger page), and a multi-dashboard workbook
# had to be hand-stacked into one composite before record-visual-check would
# accept it. Offline: Sigma's workbook GET is stubbed in-process and
# SIGMA_PYTHON points at a fake renderer that writes a PNG per --page.

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/png_stack'
require_relative 'lib/png_classify'

DIR = __dir__
$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A noisy RGBA PNG (> 5 KB once deflated) whose colour encodes the page.
def fake_png(path, seed, w: 120, h: 80)
  rng = Random.new(seed)
  rows = Array.new(h) { Array.new(w) { [rng.rand(256), (seed * 40) % 256, rng.rand(256), 255] }.flatten }
  PngStack.write_rgba(path, w, rows)
end

Dir.mktmpdir do |tmp|
  fake = File.join(tmp, 'fake-python')
  File.write(fake, <<~RB)
    #!#{RbConfig.ruby}
    if ARGV == ['--version'] then puts 'Python 3.11.0'; exit 0 end
    $LOAD_PATH.unshift #{File.join(DIR, 'lib').inspect}
    require 'png_stack'
    out = ARGV[ARGV.index('--out') + 1]
    page = ARGV[ARGV.index('--page') + 1]
    File.open(#{File.join(tmp, 'calls.log').inspect}, 'a') { |f| f.puts page }
    rng = Random.new(page.sum)
    rows = Array.new(80) { Array.new(120) { [rng.rand(256), (page.sum * 40) % 256, rng.rand(256), 255] }.flatten }
    PngStack.write_rgba(out, 120, rows)
  RB
  File.chmod(0o755, fake)
  # The shared REST client always speaks TLS, so instead of a stub server the
  # CLI runs in-process with Sigma.request stubbed AFTER the real client loads
  # (fidelity-loop's own require_relative is then a no-op).
  harness = File.join(tmp, 'harness.rb')
  File.write(harness, <<~RB)
    require #{File.join(DIR, 'lib', 'sigma_rest.rb').inspect}
    Sigma.define_singleton_method(:request) { |*_a, **_k| { 'latestDocumentVersion' => '7', 'documentVersion' => '7' } }
    load #{File.join(DIR, 'fidelity-loop.rb').inspect}
  RB
  env = { 'SIGMA_BASE_URL' => 'https://api.example.invalid', 'SIGMA_API_TOKEN' => 'offline-test', 'FIDELITY_LOOP_CLI' => '1',
          'SIGMA_PYTHON' => fake, 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }

  wd = File.join(tmp, 'wd')
  Dir.mkdir(wd)
  Dir.mkdir(File.join(wd, 'dashboards'))
  pages = [%w[page-data Data], %w[page-dash-1 Overview], %w[page-dash-2 Customers], %w[page-dash-3 Operations]]
  File.write(File.join(wd, 'wb-ids.json'), JSON.generate(
    'pages' => pages.map { |id, nm| { 'id' => id, 'name' => nm, 'elements' => [{ 'id' => "e-#{id}", 'kind' => 'bar-chart' }] } }
  ))
  File.write(File.join(wd, 'dashboard-layout.json'), JSON.generate(%w[Overview Customers Operations].map { |d| { 'dashboard' => d, 'zones' => [] } }))
  %w[Overview Customers Operations].each_with_index { |d, i| fake_png(File.join(wd, 'dashboards', "#{d}.png"), 10 + i) }

  run = lambda do |*args|
    Open3.capture2e(env, RbConfig.ruby, harness, *args)
  end
  out, st = run.call('init', '--workdir', wd, '--workbook-id', 'wb-1', '--page-id', 'page-dash-1')
  ok(st.success?, "init (#{out.lines.last.to_s.strip})")
  calls = File.join(tmp, 'calls.log')

  puts 'multi-dashboard workbook: one composite pass over every dashboard page'
  out, st = run.call('render', '--workdir', wd)
  rendered = File.exist?(calls) ? File.readlines(calls).map(&:strip) : []
  ok(st.success?, "render exits 0 (#{out.lines.grep(/FATAL|composite|OK|Error/).first(3).join(' | ').strip})")
  puts out unless st.success?
  ok(rendered == %w[page-dash-1 page-dash-2 page-dash-3], "rendered the 3 dashboard pages in source order, not Data (got #{rendered.inspect})")
  comp = PngClassify.decode_png(File.join(wd, 'rcf-pass-1.png'))
  ok(comp && comp[:w] == 120 && comp[:h] == 80 * 3 + PngStack::GAP * 2, "rcf-pass-1.png is the stacked composite (#{comp && [comp[:w], comp[:h]].inspect})")
  src = PngClassify.decode_png(File.join(wd, 'source-composite.png'))
  ok(src && src[:h] == comp[:h], 'matching source-composite.png written in the same page order')
  led = JSON.parse(File.read(File.join(wd, 'fidelity-ledger.json')))
  last = Array(led['renders']).last || {}
  ok(last['composite'] == true && last['pages'] == %w[page-dash-1 page-dash-2 page-dash-3] &&
     last['path'].end_with?('rcf-pass-1.png'), "ledger render entry records the composite (#{last.slice('pages', 'composite').inspect})")
  ok(led['source_image'] == File.join(wd, 'source-composite.png') &&
     out.include?("SOURCE to compare against: #{File.join(wd, 'source-composite.png')}"),
     'ledger and printed comparison hint point to the matching source composite')

  puts '--page-id renders THAT page (was ignored)'
  File.delete(calls)
  out, st = run.call('render', '--workdir', wd, '--page-id', 'page-dash-3')
  rendered = File.readlines(calls).map(&:strip)
  ok(st.success? && rendered == %w[page-dash-3], "only page-dash-3 rendered (got #{rendered.inspect}; #{out.lines.grep(/FATAL/).first})")
  one = PngClassify.decode_png(File.join(wd, 'rcf-pass-2.png'))
  ok(one && one[:h] == 80, 'rcf-pass-2.png is the single page')
  led = JSON.parse(File.read(File.join(wd, 'fidelity-ledger.json')))
  ok(led['source_image'] == File.join(wd, 'dashboards', 'Operations.png'),
     'single-page render restores its matching source instead of retaining the composite')

  puts '--single-page keeps the ledger page only'
  File.delete(calls)
  _out, st = run.call('render', '--workdir', wd, '--single-page')
  ok(st.success? && File.readlines(calls).map(&:strip) == %w[page-dash-1], 'ledger page only')
end

puts
if $fails.empty?
  puts 'ALL PASS'
  exit 0
end
puts "FAILURES (#{$fails.size})"
$fails.each { |x| puts "  - #{x}" }
exit 1
