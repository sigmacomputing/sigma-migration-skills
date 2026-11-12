#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline tests for lib/pbi_extract_cache.rb: the Phase 0/1 rerun cache of
# migrate-powerbi.rb (input fingerprint recorded in run-provenance.json; extraction
# skipped on a match or with --reuse-extract).
#
# Run: ruby scripts/test-pbi-extract-cache.rb
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/pbi_extract_cache'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

SCRIPTS = __dir__

Dir.mktmpdir('pbi-extract-cache') do |dir|
  work = File.join(dir, 'work')
  FileUtils.mkdir_p(work)
  pbix = File.join(dir, 'Sales.pbix')
  tmsl = File.join(dir, 'model.bim')
  pbir = File.join(dir, 'bundle.json')
  File.binwrite(pbix, 'pbix-bytes-v1')
  File.write(tmsl, '{"model":{}}')
  File.write(pbir, '{"report.json":"{}"}')

  fp_pbix = ->(name: nil, scripts_dir: SCRIPTS) { PbiExtractCache.fingerprint(pbix: pbix, tmsl: nil, pbir: nil, name: name, scripts_dir: scripts_dir) }
  fp_fab = -> { PbiExtractCache.fingerprint(pbix: nil, tmsl: tmsl, pbir: pbir, name: 'ignored', scripts_dir: SCRIPTS) }

  puts "\n1. fingerprint identity"
  a = fp_pbix.call
  check(a['route'] == 'pbix' && a['inputs'].keys == ['pbix'] && a['inputs']['pbix'].start_with?('sha256:'), 'pbix route digests the .pbix content')
  check(PbiExtractCache.same?(a, fp_pbix.call), 'identical inputs fingerprint equal')
  File.binwrite(pbix, 'pbix-bytes-v2')
  check(!PbiExtractCache.same?(a, fp_pbix.call), 'a changed .pbix changes the fingerprint')
  File.binwrite(pbix, 'pbix-bytes-v1')
  check(PbiExtractCache.same?(a, fp_pbix.call), 'restoring the bytes restores the fingerprint (content, not mtime)')
  check(!PbiExtractCache.same?(fp_pbix.call(name: 'A'), fp_pbix.call(name: 'B')), 'the --name baked into model.bim is part of the pbix fingerprint')
  b = fp_fab.call
  check(b['route'] == 'tmsl-pbir' && b['inputs'].keys.sort == %w[pbir tmsl] && b['name'] == '', 'tmsl/pbir route digests both inputs; --name is not part of it')
  File.write(pbir, '{"report.json":"{\"x\":1}"}')
  check(!PbiExtractCache.same?(b, fp_fab.call), 'a changed --pbir changes the fingerprint')
  File.write(pbir, '{"report.json":"{}"}')

  puts "\n2. an upgraded extractor invalidates the cache"
  alt = File.join(dir, 'scripts')
  FileUtils.mkdir_p(File.join(alt, 'lib'))
  PbiExtractCache::EXTRACTOR_SCRIPTS.each { |f| File.write(File.join(alt, f), "print('v1')\n") }
  f1 = fp_pbix.call(scripts_dir: alt)
  File.write(File.join(alt, 'extract-model-pbix.py'), "print('v2')\n")
  check(!PbiExtractCache.same?(f1, fp_pbix.call(scripts_dir: alt)), 'editing extract-model-pbix.py changes the fingerprint')
  f2 = fp_pbix.call(scripts_dir: alt)
  File.write(File.join(alt, 'lib', 'helper.py'), "X = 1\n")
  check(!PbiExtractCache.same?(f2, fp_pbix.call(scripts_dir: alt)), 'a scripts/lib/*.py helper is part of the extractor digest')
  check(!PbiExtractCache.same?({ 'route' => 'pbix', 'inputs' => { 'pbix' => nil }, 'name' => '', 'extractor' => 'x' },
                               { 'route' => 'pbix', 'inputs' => { 'pbix' => nil }, 'name' => '', 'extractor' => 'x' }),
        'a missing input never matches (even against itself)')

  puts "\n2b. data files the extractors load + the warehouse dialect + pbixray are part of the fingerprint"
  cat = File.join(dir, 'refs', 'catalogs')
  FileUtils.mkdir_p(cat)
  PbiExtractCache::EXTRACTOR_DATA_FILES.each { |f| File.write(File.join(cat, File.basename(f)), '{"rows":[]}') }
  g1 = fp_pbix.call(scripts_dir: alt)
  File.write(File.join(cat, 'viz-kind.json'), '{"rows":[{"visualType":"x"}]}')
  check(!PbiExtractCache.same?(g1, fp_pbix.call(scripts_dir: alt)), 'a viz-kind.json edit (scripts unchanged) invalidates the cache')
  g2 = fp_pbix.call(scripts_dir: alt)
  File.write(File.join(cat, 'custom-visual.json'), '{"x":1}')
  check(!PbiExtractCache.same?(g2, fp_pbix.call(scripts_dir: alt)), 'a custom-visual.json edit invalidates the cache')
  check(PbiExtractCache::EXTRACTOR_DATA_FILES.sort == %w[refs/catalogs/custom-visual.json refs/catalogs/viz-kind.json],
        'the data-file list names exactly the catalogs pbi_viz_kind.py opens')
  fpd = lambda { |dialect, pbixray = nil, route_pbix = true|
    PbiExtractCache.fingerprint(pbix: route_pbix ? pbix : nil, tmsl: tmsl, pbir: pbir, name: 'n', scripts_dir: SCRIPTS,
                                dialect: dialect, pbixray: pbixray)
  }
  check(!PbiExtractCache.same?(fpd.call('snowflake'), fpd.call('bigquery')), 'the dialect is part of the pbix-route identity')
  check(PbiExtractCache.same?(fpd.call('bigquery'), fpd.call('bigquery')), 'same dialect fingerprints equal')
  check(PbiExtractCache.same?(fpd.call('snowflake', nil, false), fpd.call('bigquery', nil, false)),
        'the tmsl/pbir route does not depend on the dialect (no Enter-data decoding there)')
  check(!PbiExtractCache.same?(fpd.call('snowflake', '1.0.0'), fpd.call('snowflake', '1.1.0')), 'the pbixray version is part of the identity')
  Dir.mktmpdir('fakepy') do |fd|
    fake = File.join(fd, 'py')
    File.write(fake, "#!/bin/sh\necho 7.8.9\n")
    File.chmod(0o755, fake)
    check(PbiExtractCache.pbixray_version([fake]) == '7.8.9', 'pbixray_version reads the version through the configured python')
    check(PbiExtractCache.pbixray_version([File.join(fd, 'missing')]).nil?, 'an unusable python means "skip", never an error')
  end

  puts "\n3. large inputs are sampled, not fully read"
  big = File.join(dir, 'big.bin')
  File.binwrite(big, 'a' * 100 + 'b' * 100)
  full = PbiExtractCache.file_digest(big)
  PbiExtractCache.send(:remove_const, :SAMPLE_ABOVE)
  PbiExtractCache.const_set(:SAMPLE_ABOVE, 10)
  PbiExtractCache.send(:remove_const, :SAMPLE_BYTES)
  PbiExtractCache.const_set(:SAMPLE_BYTES, 16)
  sampled = PbiExtractCache.file_digest(big)
  check(full.start_with?('sha256:') && sampled.start_with?('sampled-sha256:') && sampled.include?(':200:'), "above the threshold the digest is head+tail+size+mtime (#{sampled[0, 40]}...)")
  File.binwrite(big, 'a' * 100 + 'b' * 99 + 'c')
  check(PbiExtractCache.file_digest(big) != sampled, 'a change in the tail changes the sampled digest')
  PbiExtractCache.send(:remove_const, :SAMPLE_ABOVE)
  PbiExtractCache.const_set(:SAMPLE_ABOVE, 512 * 1024 * 1024)
  PbiExtractCache.send(:remove_const, :SAMPLE_BYTES)
  PbiExtractCache.const_set(:SAMPLE_BYTES, 4 * 1024 * 1024)

  puts "\n4. decide: when the extraction is skipped"
  cur = fp_pbix.call
  d = PbiExtractCache.decide(work, cur)
  check(!d['reuse'] && d['reason'].include?('no recorded input fingerprint'), 'first run: nothing recorded -> extract')

  File.write(File.join(work, 'run-provenance.json'), JSON.generate('pluginVersion' => '1'))
  PbiExtractCache.record(work, cur, 87.4)
  prov = JSON.parse(File.read(File.join(work, 'run-provenance.json')))
  check(prov['pluginVersion'] == '1' && prov['extractFingerprint']['inputs'] == cur['inputs'] && prov['extractFingerprint']['extractSeconds'] == 87.4,
        'record() merges the fingerprint + extraction time into run-provenance.json without losing other keys')

  d = PbiExtractCache.decide(work, cur)
  check(!d['reuse'] && d['reason'].include?('missing'), 'fingerprint matches but the extracted files are gone -> extract')

  %w[model.bim signals.json report-layout.json].each { |f| File.write(File.join(work, f), '{}') }
  d = PbiExtractCache.decide(work, cur)
  check(d['reuse'] && d['mode'] == 'fingerprint' && d['saved_seconds'] == 87.4, 'fingerprint match + files present -> reuse automatically')
  check(PbiExtractCache.timings_note(d, 1.2).include?('saved ~86s of the original 87s'), 'the timings note says what was saved')
  check(PbiExtractCache.timings_note({ 'mode' => 'forced', 'saved_seconds' => 0.1 }, 0.0) == 'extract-cache: reused Phase 0/1 extraction (forced)', 'a sub-second saving is not advertised')

  File.binwrite(pbix, 'pbix-bytes-v2')
  d = PbiExtractCache.decide(work, fp_pbix.call)
  check(!d['reuse'] && d['reason'].include?('changed'), 'changed input -> extract')
  d = PbiExtractCache.decide(work, fp_pbix.call, forced: true)
  check(d['reuse'] && d['mode'] == 'forced' && d['reason'].include?('DIFFERS'), '--reuse-extract reuses despite a changed input, and says so')
  File.binwrite(pbix, 'pbix-bytes-v1')

  d = PbiExtractCache.decide(work, cur, disabled: true)
  check(!d['reuse'] && d['reason'].include?('--no-reuse-extract'), '--no-reuse-extract always extracts')

  FileUtils.rm(File.join(work, 'report-layout.json'))
  d = PbiExtractCache.decide(work, cur, forced: true)
  check(!d['reuse'] && d['reason'].include?('report-layout.json'), '--reuse-extract with a missing file falls back to extracting and names the file')
  File.write(File.join(work, 'report-layout.json'), '{}')

  PbiExtractCache.clear(work)
  check(PbiExtractCache.recorded(work).nil?, 'clear() drops the fingerprint')
  d = PbiExtractCache.decide(work, cur, forced: true)
  check(d['reuse'] && d['reason'].include?('no input fingerprint recorded'), '--reuse-extract with files present but no fingerprint reuses (the user asked)')

  puts "\n5. the Fabric route needs only signals.json"
  fab_work = File.join(dir, 'fab')
  FileUtils.mkdir_p(fab_work)
  fab = fp_fab.call
  File.write(File.join(fab_work, 'signals.json'), '{"pages":[]}')
  PbiExtractCache.record(fab_work, fab, 3.0)
  check(PbiExtractCache.decide(fab_work, fab)['reuse'], 'tmsl/pbir route reuses with signals.json alone (the model is the user\'s --tmsl)')
end

puts
if FAILS.empty?
  puts 'ALL PASS'
else
  puts "#{FAILS.size} FAILED:"
  FAILS.each { |x| puts "  - #{x}" }
  exit 1
end
