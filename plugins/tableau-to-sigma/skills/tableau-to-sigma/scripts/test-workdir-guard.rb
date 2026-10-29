#!/usr/bin/env ruby
# frozen_string_literal: true

# lib/workdir_guard.rb (+ .py twin): a run's workdir may never sit inside the
# installed skill / plugin or a .claude/plugins cache|marketplace install. Real
# failure: an agent cd'd into the skill dir and passed it (or `.`) as --workdir,
# so run artifacts were written into — and read back from — the shared install.
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

SCRIPTS = __dir__
SKILL = File.expand_path('..', SCRIPTS)
PLUGIN_ROOT = File.expand_path('..', File.dirname(SKILL)) # <plugin>/skills/<skill> -> <plugin>
require File.join(SCRIPTS, 'lib', 'workdir_guard')

$failures = []
def check(description, condition)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{description}"
  $failures << description unless condition
end

def refused?(path)
  !WorkdirGuard.violation(path).nil?
end

def run_ruby(script, *args, chdir: SCRIPTS)
  # Test harness: runs a skill script by this file's literal name; args are literals or temp paths.
  # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
  Open3.capture3(RbConfig.ruby, File.join(SCRIPTS, script), *args, chdir: chdir)
end

# A guard refusal: the dedicated exit code, the REFUSED banner, and the fix named.
def refusal?(out, err, status)
  !status.success? && status.exitstatus == WorkdirGuard::EXIT_CODE &&
    (out + err).include?('REFUSED') && (out + err).include?('~/tableau-migration/<name>')
end

ENV.delete(WorkdirGuard::ESCAPE_ENV)

Dir.mktmpdir('workdir-guard-') do |tmp|
  tmp = File.realpath(tmp)
  puts 'WorkdirGuard.violation refuses installed-plugin locations'
  check('the skill directory', refused?(SKILL))
  check('the plugin root', refused?(PLUGIN_ROOT))
  check('a subdir of the skill dir (not yet created)', refused?(File.join(SKILL, 'run-x', 'views')))
  check('a sibling skill under the plugin root', refused?(File.join(PLUGIN_ROOT, 'skills', 'other-skill')))
  Dir.chdir(SKILL) do
    check('"." from the skill dir', refused?('.'))
    check('"scripts" relative to the skill dir', refused?('scripts'))
    check('".." from scripts/ (the skill dir again)', Dir.chdir('scripts') { refused?('..') })
  end

  fake_cache = File.join(tmp, '.claude', 'plugins', 'cache', 'sigma-migration-skills', 'tableau-to-sigma', '9.9.9', 'skills', 'tableau-to-sigma')
  FileUtils.mkdir_p(fake_cache)
  check('a .claude/plugins/cache path', refused?(fake_cache))
  check('a subdir of it', refused?(File.join(fake_cache, 'wd')))
  check('a .claude/plugins/marketplaces path', refused?(File.join(tmp, '.claude', 'plugins', 'marketplaces', 'm', 'wd')))
  check('.CLAUDE/Plugins/Cache differing only in case (case-insensitive hosts)',
        !WorkdirGuard.case_insensitive? || refused?(File.join(tmp, '.CLAUDE', 'Plugins', 'CACHE', 'x')))
  check('the skill dir spelled in a different case (case-insensitive hosts)',
        !WorkdirGuard.case_insensitive? || refused?(SKILL.swapcase))

  link = File.join(tmp, 'looks-innocent')
  begin
    File.symlink(SKILL, link)
    check('a symlink pointing into the skill dir', refused?(link))
    check('a path through that symlink', refused?(File.join(link, 'newdir')))
  rescue NotImplementedError, SystemCallError => e
    puts "  SKIP  symlink checks (#{e.class})"
  end

  puts 'WorkdirGuard.violation accepts ordinary workdirs'
  home_dir = File.expand_path('~/tableau-migration/x')
  check('a temp dir', !refused?(tmp))
  check('a not-yet-created subdir of a temp dir', !refused?(File.join(tmp, 'new', 'run')))
  check('~/tableau-migration/x', !refused?(home_dir))
  check('nil / empty are not a violation (flag absent)', !refused?(nil) && !refused?(''))

  puts 'check! / check_file!'
  out_file = File.join(tmp, 'out.json')
  check('check! returns an acceptable path unchanged', WorkdirGuard.check!(tmp, '--workdir') == tmp)
  check('check_file! returns an acceptable file path unchanged', WorkdirGuard.check_file!(out_file, '--out') == out_file)
  check('a file inside the skill dir is refused via its directory', refused?(File.dirname(File.join(SKILL, 'out.json'))))
  ENV[WorkdirGuard::ESCAPE_ENV] = '1'
  check('SIGMA_ALLOW_WORKDIR_IN_SKILL=1 bypasses the guard', WorkdirGuard.check!(SKILL, '--workdir') == SKILL)
  ENV.delete(WorkdirGuard::ESCAPE_ENV)

  puts 'a copy installed under .claude/plugins/cache protects its own skill + plugin root'
  inst_skill = File.join(tmp, 'inst', '.claude', 'plugins', 'cache', 'mk', 'tableau-to-sigma', '1.0.0', 'skills', 'tableau-to-sigma')
  FileUtils.mkdir_p(File.join(inst_skill, 'scripts', 'lib'))
  FileUtils.cp(File.join(SCRIPTS, 'lib', 'workdir_guard.rb'), File.join(inst_skill, 'scripts', 'lib'))
  probe = <<~RUBY
    require #{File.join(inst_skill, 'scripts', 'lib', 'workdir_guard').inspect}
    skill = #{inst_skill.inspect}
    plugin = File.expand_path('../..', skill)
    ok = [skill, plugin, File.join(skill, 'x'), File.join(plugin, 'README')].all? { |p| WorkdirGuard.violation(p) }
    ok &&= WorkdirGuard.violation(File.join(#{tmp.inspect}, 'work')).nil?
    puts(ok ? 'probe-ok' : 'probe-bad')
  RUBY
  out, _err, st = Open3.capture3(RbConfig.ruby, '-e', probe)
  check('installed copy refuses itself/its plugin root and accepts an outside dir', st.success? && out.include?('probe-ok'))

  puts 'Subprocess: entry points exit non-zero with the fix named'
  o, e, s = run_ruby('migrate-tableau.rb', '--workbook', 'Synthetic', '--connection', 'x', '--workdir', SKILL, chdir: SKILL)
  check('migrate-tableau.rb --workdir <skill dir> refuses', refusal?(o, e, s))
  check('...and names the flag to pass', (o + e).include?('--workdir ~/tableau-migration/<name>'))
  o, e, s = run_ruby('migrate-tableau.rb', '--workbook', 'Synthetic', '--connection', 'x', '--out', '.', chdir: SKILL)
  check('migrate-tableau.rb --out . (cwd = skill dir) refuses', refusal?(o, e, s))
  o, e, s = run_ruby('build-charts-from-signals.rb', '--tableau-dir', '.', chdir: SKILL)
  check('build-charts-from-signals.rb --tableau-dir . (cwd = skill dir) refuses', refusal?(o, e, s))
  o, e, s = run_ruby('build-source-object-census.rb', '--workdir', File.join(SKILL, 'scripts'))
  check('build-source-object-census.rb --workdir <skill>/scripts refuses', refusal?(o, e, s))
  o, e, s = run_ruby('post-and-readback.rb', '--type', 'workbook', '--spec', File.join(SKILL, 'scripts', 'x.json'), '--out', out_file)
  check('post-and-readback.rb with the default workdir (dir of --spec) in the skill dir refuses', refusal?(o, e, s))
  twb = File.join(tmp, 'a.twb')
  File.write(twb, '<workbook/>')
  report = File.join(SKILL, 'guard-test-gaps.md')
  o, e, s = run_ruby('scan-workbook-gaps.rb', twb, report)
  check('scan-workbook-gaps.rb writing its report into the skill dir refuses', refusal?(o, e, s))
  check('...and wrote nothing there', !File.exist?(report) && !File.exist?(File.join(SKILL, 'formula-audit.json')))
  o, e, s = run_ruby('build-charts-from-signals.rb', '--tableau-dir', tmp, '--out', File.join(tmp, 'c.json'))
  check('a temp --tableau-dir is NOT refused by the guard', !(o + e).include?('REFUSED'))

  py = ENV['PYTHON3'] || 'python3'
  begin
    o, e, s = Open3.capture3(py, File.join(SCRIPTS, 'migrate-tableau.py'), '--workbook', 'Synthetic', '--connection', 'x',
                             '--folder', 'f', '--db', 'D', '--schema', 'S', '--landing', 'n/a', '--out', SKILL)
    check('migrate-tableau.py --out <skill dir> refuses (Python twin)', refusal?(o, e, s))
    o, e, s = Open3.capture3(py, File.join(SCRIPTS, 'build-source-object-census.py'), '--workdir', '.', chdir: SKILL)
    check('build-source-object-census.py --workdir . refuses (Python twin)', refusal?(o, e, s))
    o, e, s = Open3.capture3(py, File.join(SCRIPTS, 'scan-workbook-gaps.py'), twb, report)
    check('scan-workbook-gaps.py output dir in the skill dir refuses (Python twin)', refusal?(o, e, s))
    check('...and wrote nothing there', !File.exist?(report))

    cases = [SKILL, PLUGIN_ROOT, File.join(SKILL, 'a', 'b'), link, fake_cache, tmp, home_dir]
    twin = <<~PY
      import sys
      sys.path.insert(0, #{File.join(SCRIPTS, 'lib').inspect})
      import workdir_guard as g
      cases = #{cases.inspect}
      print(','.join('1' if g.violation(c) else '0' for c in cases))
    PY
    out, _err, st = Open3.capture3(py, '-c', twin)
    check('Python twin agrees with Ruby on every case',
          st.success? && out.strip == cases.map { |c| refused?(c) ? '1' : '0' }.join(','))
  rescue Errno::ENOENT
    puts '  SKIP  python3 not available'
  end
end

if $failures.empty?
  puts "\nOK: workdir guard"
  exit 0
end
puts "\nFAIL: #{$failures.size} check(s)"
exit 1
