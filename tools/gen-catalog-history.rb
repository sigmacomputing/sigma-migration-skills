#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tools/gen-catalog-history.rb — generate (or --check) the platform-difference
# catalog HISTORY: shared/refs/sigma-platform-differences-history.json.
#
# WHY. A blind-grade/v2 grade records the catalog's catalog_sha256. Without a
# history, every catalog addition changed that sha and invalidated every
# in-flight grade (live: adding pivot-row-height-fixed on 2026-11-09 forced
# fresh re-grades of Complex Pivot). The history maps each earlier catalog sha
# to its entry ids and per-entry content hashes, so BlindGrade.catalog_compat
# can accept a grade made against an ANCESTOR catalog whose entries are all
# still in the shipped catalog with identical content. A removed or changed
# entry, or an unknown sha, is still refused.
#
#   ruby tools/gen-catalog-history.rb           # (re)write the history
#   ruby tools/gen-catalog-history.rb --check   # CI: exit 1 when it is stale
#
# Records come from (in this order, de-duplicated by sha): the records already
# in the history file (so a catalog revision that only lived on a squashed
# branch is never lost), every committed revision of the catalog in git
# (oldest first; none in a shallow clone), and the working-tree catalog. A
# revision that does not load as a valid catalog is skipped (no grade could
# validate against it). Per-entry hashes are recomputed from the bytes for every
# sha git (or the working tree) can still reach; older records are kept as
# written (harmless: catalog_compat only accepts ids the CURRENT catalog has
# with identical content).
#
# After a write, run `ruby tools/sync-shared.rb` to vendor it into the plugins.

require 'open3'
require_relative '../shared/lib/ruby_compat'
require_relative '../shared/lib/blind_grade'

ROOT = File.expand_path('..', __dir__)
CATALOG_REL = 'shared/refs/sigma-platform-differences.json'
HISTORY_REL = 'shared/refs/sigma-platform-differences-history.json'

module CatalogHistory
  module_function

  # [[sha, {id => entry_hash}], ...] for each committed revision, oldest first.
  def git_revisions(root, rel)
    # git log/show on this repo's own catalog path, as an argument list (no shell).
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, st = Open3.capture2('git', '-C', root, 'log', '--format=%H', '--reverse', '--', rel)
    return [] unless st.success?
    out.split.filter_map do |commit|
      # git log/show on this repo's own catalog path, as an argument list (no shell).
      # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
      bytes, st2 = Open3.capture2('git', '-C', root, 'show', "#{commit}:#{rel}", binmode: true)
      next nil unless st2.success?
      record(bytes)
    end
  end

  # [sha, {id => entry_hash}] for valid catalog bytes, else nil.
  def record(bytes)
    c = BlindGrade.parse_catalog_bytes(bytes)
    c['errors'].empty? ? [c['sha256'], c['entry_hashes']] : nil
  end

  # The existing history file's records. A file that exists but does not
  # parse (e.g. merge-conflict markers) ABORTS: silently rebuilding it would
  # drop records git cannot reproduce (squash-merged branches).
  def existing(path)
    return [] unless File.file?(path)
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      abort "FATAL: #{path} is not valid JSON (#{e.message.lines.first.strip}) — resolve it by hand (keep every record), then re-run"
    end
    Array(doc.is_a?(Hash) ? doc['catalogs'] : nil).filter_map do |c|
      next nil unless c.is_a?(Hash) && c['sha256'].to_s =~ BlindGrade::HEX64 && c['entries'].is_a?(Hash)
      [c['sha256'].to_s, c['entries']]
    end
  end

  # Merge record sources in order; a later source's recomputed hashes win for a
  # sha it also has (git/worktree bytes are the truth for that sha).
  def merge(*sources)
    order = []
    by_sha = {}
    sources.each do |src|
      src.each do |sha, ents|
        order << sha unless by_sha.key?(sha)
        by_sha[sha] = ents
      end
    end
    order.map { |sha| [sha, by_sha[sha]] }
  end

  # Deterministic text (no JSON.pretty_generate: its empty-container output
  # differs across json gem versions, which would make --check flaky).
  def render(records)
    lines = []
    lines << '{'
    lines << "  \"schema\": #{BlindGrade.canonical_str(BlindGrade::HISTORY_SCHEMA)},"
    lines << '  "generated_by": "tools/gen-catalog-history.rb (do not edit by hand; CI runs it with --check)",'
    lines << '  "entry_hash": "sha256 of the entry as canonical JSON: keys sorted, no whitespace, non-printable-ASCII as lowercase \\\\uXXXX",'
    lines << '  "catalogs": ['
    records.each_with_index do |(sha, ents), i|
      lines << '    {'
      lines << "      \"sha256\": #{BlindGrade.canonical_str(sha)},"
      if ents.empty?
        lines << '      "entries": {}'
      else
        lines << '      "entries": {'
        ents.each_with_index do |(id, h), j|
          lines << "        #{BlindGrade.canonical_str(id)}: #{BlindGrade.canonical_str(h)}#{j == ents.size - 1 ? '' : ','}"
        end
        lines << '      }'
      end
      lines << "    }#{i == records.size - 1 ? '' : ','}"
    end
    lines << '  ]'
    lines << '}'
    "#{lines.join("\n")}\n"
  end

  # → [text, current_sha] for the repo at root.
  def generate(root: ROOT, catalog_rel: CATALOG_REL, history_rel: HISTORY_REL, use_git: true)
    cat_path = File.join(root, catalog_rel)
    current = record(File.binread(cat_path))
    abort "FATAL: #{catalog_rel} does not load as a valid catalog — fix it first" unless current
    records = merge(existing(File.join(root, history_rel)),
                    use_git ? git_revisions(root, catalog_rel) : [],
                    [current])
    [render(records), current[0]]
  end
end

if $PROGRAM_NAME == __FILE__
  check = ARGV.delete('--check')
  abort 'usage: ruby tools/gen-catalog-history.rb [--check]' unless ARGV.empty?
  text, cur = CatalogHistory.generate
  path = File.join(ROOT, HISTORY_REL)
  if check
    have = File.file?(path) ? File.read(path) : nil
    if have == text
      n = JSON.parse(text)['catalogs'].length
      puts "catalog history OK: #{HISTORY_REL} lists #{n} catalog(s), current #{cur[0, 12]}…"
      exit 0
    end
    warn "FAIL: #{HISTORY_REL} is #{have.nil? ? 'missing' : 'stale'} — the shipped catalog (#{cur[0, 12]}…) or a past"
    warn '      revision of it is not recorded (or a record was edited by hand). A grade made against an'
    warn '      earlier catalog can only be accepted when the history lists it. Regenerate and vendor:'
    warn '        ruby tools/gen-catalog-history.rb && ruby tools/sync-shared.rb'
    exit 1
  end
  File.write(path, text)
  puts "wrote #{HISTORY_REL} (current #{cur[0, 12]}…). Now run: ruby tools/sync-shared.rb"
end
