#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for issue #685-A (Superstore cold-run failure, 2026-08-08).
#
# THE BUG: migrate-tableau.rb's embedded-extract-landing gate used
# `HydrateCustomSql.twb_has_sqlproxy?(twb)` — a WORKBOOK-scoped question ("does
# this .twb contain ANY sqlproxy datasource anywhere") — to decide whether to
# run extract-landing + MechanicalSpecs.remap_from_manifest! for the ENTIRE
# workbook. A workbook mixing an unrelated sqlproxy-backed published datasource
# (e.g. a "Commission Model" dashboard fed by a published DS) with a perfectly
# landable embedded Hyper extract (e.g. "Sample - Superstore") saw the sqlproxy
# sibling disable landing/remap for BOTH datasources — the landable one never
# got remapped, so its DM element kept the converter's placeholder name/path
# ("UNKNOWN" / ["TJ","UNKNOWN"], missing the database segment) all the way to
# a live POST ("Source not found: warehouse table 'TJ.UNKNOWN'").
#
# THE FIX: sqlproxy detection must be scoped PER-DATASOURCE. This test guards
# two new HydrateCustomSql functions:
#   sqlproxy_only_datasource_names(twb) — which datasource(s) are sqlproxy
#     placeholders with no real relation (the ones hydrate-custom-sql.rb's
#     PDS-chase path still owns).
#   non_sqlproxy_conn_classes(twb) — the connection classes carried by every
#     OTHER (non-sqlproxy) datasource, i.e. exactly what migrate-tableau.rb
#     needs to decide "is the REMAINING workbook fully embedded-extract and
#     therefore landable" WITHOUT an unrelated sqlproxy sibling polluting the
#     answer with a stray 'sqlproxy' class.
#
# Deterministic + offline: hand-built .twb fixture mirroring the real
# Superstore shape (never the customer's own workbook — Tableau's own sample
# content), no network / creds.
#
# Usage:  ruby scripts/test-sqlproxy-per-datasource.rb

require 'tempfile'
require_relative 'hydrate-custom-sql'

fails = []
def check(cond, msg, fails) fails << msg unless cond; puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}" end

H = HydrateCustomSql

# Mirrors the real Superstore shape: an embedded Hyper extract federation
# ("Sample - Superstore") feeding 5 landable dashboards, PLUS an unrelated
# sqlproxy-backed "Commission Model" published datasource (file-based PDS,
# no landing path) feeding a separate dashboard. Bug #685-A: the sqlproxy
# sibling must not blind the orchestrator to the landable one.
MIXED_TWB = <<~XML
  <workbook>
    <datasources>
      <datasource caption='Sample - Superstore' name='federated.superstore'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='hyper.orders'>
              <connection class='hyper' dbname='Data/Superstore.hyper' />
            </named-connection>
          </named-connections>
          <relation name='Orders' table='[Orders]' type='table' />
        </connection>
      </datasource>
      <datasource caption='Commission Model' name='sqlproxy.commission'>
        <connection class='sqlproxy' dbname='CommissionModelPDS'>
          <relation name='sqlproxy' table='[sqlproxy]' type='table' />
        </connection>
      </datasource>
    </datasources>
  </workbook>
XML

# A control: a workbook whose ONLY datasource is sqlproxy — nothing landable,
# non_sqlproxy_conn_classes must correctly come back empty (not a false trip).
PURE_SQLPROXY_TWB = <<~XML
  <workbook>
    <datasources>
      <datasource caption='Commission Model' name='sqlproxy.commission'>
        <connection class='sqlproxy' dbname='CommissionModelPDS'>
          <relation name='sqlproxy' table='[sqlproxy]' type='table' />
        </connection>
      </datasource>
    </datasources>
  </workbook>
XML

puts 'Part A — mixed workbook: sqlproxy detection is per-datasource, not per-workbook'
Tempfile.create(['mixed', '.twb']) do |f|
  f.write(MIXED_TWB); f.flush
  check(H.twb_has_sqlproxy?(f.path), 'workbook-level twb_has_sqlproxy? stays true (unchanged behavior)', fails)
  names = H.sqlproxy_only_datasource_names(f.path)
  check(names == ['sqlproxy.commission'],
        "sqlproxy_only_datasource_names identifies ONLY the Commission Model datasource (got #{names.inspect})", fails)
  classes = H.non_sqlproxy_conn_classes(f.path)
  # 'federated' is the outer wrapper class on the landable datasource itself
  # (rejected by the CALLER, same as today's blunt regex scan) — the point of
  # this test is that 'sqlproxy' (from the UNRELATED Commission Model
  # datasource) never appears here at all.
  check(classes.sort == %w[federated hyper],
        "non_sqlproxy_conn_classes sees the landable sibling's classes UNPOLLUTED by the " \
        "unrelated sqlproxy datasource's class (got #{classes.inspect})", fails)
  check(!classes.include?('sqlproxy'),
        'the sqlproxy class from the unrelated Commission Model datasource never leaks into the ' \
        'embedded-extract eligibility check', fails)
end

puts 'Part B — pure-sqlproxy workbook: no landable classes (not a false trip)'
Tempfile.create(['pure_sqlproxy', '.twb']) do |f|
  f.write(PURE_SQLPROXY_TWB); f.flush
  check(H.twb_has_sqlproxy?(f.path), 'workbook-level twb_has_sqlproxy? true', fails)
  check(H.sqlproxy_only_datasource_names(f.path) == ['sqlproxy.commission'],
        'the sole datasource is correctly identified as sqlproxy-only', fails)
  check(H.non_sqlproxy_conn_classes(f.path) == [],
        'no non-sqlproxy classes remain — a pure-sqlproxy workbook has nothing to land ' \
        '(falls through to the hydration path, not landing)', fails)
end

puts 'Part C — live-table-only workbook: unaffected (no sqlproxy anywhere)'
Tempfile.create(['live', '.twb']) do |f|
  f.write("<workbook><datasources><datasource caption='L'><connection class='snowflake'>" \
          "<relation name='O' table='[A].[B].[O]' type='table'/></connection></datasource></datasources></workbook>")
  f.flush
  check(!H.twb_has_sqlproxy?(f.path), 'workbook-level twb_has_sqlproxy? false', fails)
  check(H.sqlproxy_only_datasource_names(f.path) == [], 'no sqlproxy datasources found', fails)
  check(H.non_sqlproxy_conn_classes(f.path) == ['snowflake'],
        'the single live-table datasource\'s class passes through unchanged', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
