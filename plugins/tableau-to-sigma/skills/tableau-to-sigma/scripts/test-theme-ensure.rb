#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for post-and-readback's v5.4 ensure_theme! hook: the
# source-derived theme must reach EVERY workbook spec at the POST/PUT choke
# point — mechanical and hand-authored recovery specs alike (round-6 field:
# an exit-4 recovery PUT shipped default-blue where the source declares its
# own palette, because only build_wb_spec applied the theme).
# Usage: ruby scripts/test-theme-ensure.rb
require 'json'
require 'tmpdir'

DIR = __dir__
SRC = File.read(File.join(DIR, 'post-and-readback.rb'))
m = SRC.match(/^def ensure_theme!.*?\n^end$/m) or abort('could not extract ensure_theme!')
require_relative 'lib/theme_derive'
# require_relative cannot infer a basepath inside eval — the lib is preloaded.
eval(m[0].sub(/require_relative\s+'lib\/theme_derive'/, 'nil')) # rubocop:disable Security/Eval

fails = []
def check(c, msg, fails)
  fails << msg unless c
  puts "  #{c ? 'PASS' : 'FAIL'}  #{msg}"
end

THEME = { 'categoricalScheme' => ['#0E8DA0', '#123456'], 'backgroundCanvas' => '#FFFFFF' }.freeze
SPEC  = { 'name' => 'W', 'pages' => [{ 'id' => 'p', 'elements' => [] }] }.freeze

$opts_type = 'workbook'

Dir.mktmpdir do |d|
  # theme via the flat-mode sidecar
  File.write(File.join(d, 'chart-specs-theme.json'), JSON.generate(THEME))
  out = ensure_theme!(JSON.generate(SPEC), d)
  spec = JSON.parse(out)
  check(spec.dig('themeOverrides', 'categoricalScheme') == THEME['categoricalScheme'],
        'sidecar theme applied to a spec that carried none', fails)
  check(spec['themeName'] == 'Light', 'themeName stamped by ThemeDerive.apply!', fails)

  # a spec that ALREADY carries themeOverrides is untouched
  themed = SPEC.merge('themeOverrides' => { 'categoricalScheme' => ['#ABCDEF'] })
  out2 = ensure_theme!(JSON.generate(themed), d)
  check(JSON.parse(out2)['themeOverrides'] == themed['themeOverrides'],
        'existing themeOverrides never overwritten', fails)
end

Dir.mktmpdir do |d|
  # theme via the pages-mode 'theme' key of chart-specs.json
  File.write(File.join(d, 'chart-specs.json'), JSON.generate('pages' => [], 'theme' => THEME))
  out = ensure_theme!(JSON.generate(SPEC), d)
  check(JSON.parse(out).dig('themeOverrides', 'colorOverrides', 'backgroundCanvas') == '#FFFFFF',
        "builder-output 'theme' key applied", fails)
end

Dir.mktmpdir do |d|
  # no theme anywhere → byte-identical passthrough
  body = JSON.generate(SPEC)
  check(ensure_theme!(body, d).equal?(body) || ensure_theme!(body, d) == body,
        'no derived theme → spec passes through unchanged', fails)
  # datamodel type → untouched
  $opts_type = 'datamodel'
  File.write(File.join(d, 'chart-specs-theme.json'), JSON.generate(THEME))
  check(ensure_theme!(body, d) == body, 'datamodel specs never themed', fails)
  $opts_type = 'workbook'
end

if fails.empty?
  puts 'test-theme-ensure: ALL PASS'
else
  puts "test-theme-ensure: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
