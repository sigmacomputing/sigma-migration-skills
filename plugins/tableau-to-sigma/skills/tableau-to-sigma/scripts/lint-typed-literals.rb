#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-typed-literals.rb — CLI for the typed-literal calc lint (v5.5 W2.2).
# Core logic + the field-failure story live in lib/typed_literal_lint.rb:
# numeric/temporal columns compared to quoted string literals compile clean
# in Sigma and render NULL (the 2026-07-13 If([Year] = "2014", ...) blanking).
#
# Usage:
#   ruby scripts/lint-typed-literals.rb --spec dm-spec.json --types types.json \
#        [--out findings.json]
#
#   --spec   dm-spec / workbook-spec JSON (pages[].elements[] shape)
#   --types  column-type map JSON: { "TABLE_OR_ELEMENT": { "COLUMN": "number"|
#            "text"|"datetime"|... } } — from the landing manifest, a
#            warehouse DESCRIBE, or live /columns. The map is the authority;
#            the lint never guesses from a column's name.
#   --out    optional path; findings written as a JSON array (also when empty)
#
# Exit codes:  0 = no findings   3 = findings exist (printed one per line)
#              2 = usage / unreadable / unparseable input
#
# Ruby 2.6 floor (macOS system Ruby).
require 'json'
require_relative 'lib/typed_literal_lint'

USAGE = 'usage: ruby scripts/lint-typed-literals.rb --spec dm-spec.json ' \
        '--types types.json [--out findings.json]'

spec_path = nil
types_path = nil
out_path = nil

args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when '--spec'  then spec_path = args.shift
  when '--types' then types_path = args.shift
  when '--out'   then out_path = args.shift
  when '-h', '--help'
    puts USAGE
    exit 0
  else
    warn "unknown argument: #{a}"
    warn USAGE
    exit 2
  end
end

if spec_path.to_s.empty? || types_path.to_s.empty?
  warn USAGE
  exit 2
end

def load_json(path, label)
  unless File.file?(path)
    warn "#{label} file not found: #{path}"
    exit 2
  end
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  warn "#{label} is not valid JSON (#{path}): #{e.message[0, 200]}"
  exit 2
end

spec  = load_json(spec_path, '--spec')
types = load_json(types_path, '--types')

unless spec.is_a?(Hash)
  warn "--spec must be a JSON object (got #{spec.class})"
  exit 2
end
unless types.is_a?(Hash)
  warn "--types must be a JSON object (got #{types.class})"
  exit 2
end

findings = TypedLiteralLint.lint(spec, types)

File.write(out_path, JSON.pretty_generate(findings)) if out_path

if findings.empty?
  puts 'typed-literal lint: clean (0 findings)'
  exit 0
end

findings.each do |f|
  puts "#{f['formula_owner']}: #{f['column']} is #{f['column_type']} but compared to " \
       "string #{f['literal'].inspect} — `#{f['formula_fragment']}` → fix: #{f['suggestion']}"
end
warn "typed-literal lint: #{findings.size} finding(s) — these comparisons compile clean " \
     'and render NULL for every affected measure (the 2026-07-13 blanking class)'
exit 3
