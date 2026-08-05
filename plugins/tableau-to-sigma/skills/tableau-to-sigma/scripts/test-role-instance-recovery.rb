#!/usr/bin/env ruby
# frozen_string_literal: true
# Role-instanced computed-key recovery suite (wave-3 R3-1 parity killer).
#
# The defect: a role-played date dimension (one physical date view, N date
# roles) had its recovered "order-date"-class join attached to ANOTHER role's
# DM element — Sigma compounds every relationship condition onto one element
# instance, so the fact collapsed to rows where ALL date keys agree (strict
# parity 0/5). Locked here:
#
#   1. recover_computed_key_joins! resolves the join target STRUCTURALLY (twb
#      end-point object caption + target-key guid vs converter inode ids) and,
#      when the fact key is a physical "<ROLE>_KEY" surrogate, creates a NEW
#      per-role element instance of the physical date view — never a second
#      relationship onto an existing role's element.
#   2. Ambiguous role attribution / ambiguous date view / compound-risk targets
#      are REFUSED with "GAP:"-prefixed messages and NOTHING is wired.
#   3. relationship_reachability_violations flags two relationships from one
#      carrier to the SAME target element (the collapse shape) loudly.
#   4. Re-running the recovery is idempotent (no duplicate instances/rels).
#
# Offline, node-free, invented names only.
#
# Usage:  ruby scripts/test-role-instance-recovery.rb

require 'json'
require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- invented uuids / helpers ----------------------------------------------
FK_ADMIT     = '11111111-1111-4111-8111-111111111111'
FK_DISCHARGE = '22222222-2222-4222-8222-222222222222'
DIM_KEY      = '99999999-9999-4999-8999-999999999999' # shared by role instances
SPAN_KEY     = '55555555-5555-4555-8555-555555555555' # DIM_SPANS' own key
SRC_FOLLOWUP = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' # wrapped fact column
FACT_OBJ = 'FACT_STAYS_AB12CD34EF56AB78CD90EF12AB34CD56'
SPAN_OBJ = 'DIM_SPANS_FF00000000000000000000000000000F'

def inode(seq, uuid)
  "inode-#{seq}/#{uuid.upcase[0, 24]}~x"
end

def date_dim_el(id, role, key_seq)
  { 'id' => id, 'kind' => 'table', 'name' => "DIM_DATES (#{role})",
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DIM_DATES] },
    'columns' => [
      { 'id' => inode(key_seq, DIM_KEY), 'name' => 'Date Key', 'formula' => '[DIM_DATES/Date Key]' },
      { 'id' => "inode-#{key_seq}d/DATE_DAY~x", 'name' => 'Date Day', 'formula' => '[DIM_DATES/Date Day]' }
    ] }
end

# Base model: fact + two wired role instances of DIM_DATES + a DIM_SPANS whose
# warehouse view is verifiably missing its key column (the R3-1 shape).
def base_model(discharge_path: %w[ANALYTICS PUBLIC DIM_DATES])
  admit = date_dim_el('el-admit', 'Admit Date', 'a1')
  discharge = date_dim_el('el-discharge', 'Discharge Date', 'b1')
  discharge['source']['path'] = discharge_path
  spans = { 'id' => 'el-spans', 'kind' => 'table',
            'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC DIM_SPANS] },
            'columns' => [{ 'id' => inode('s1', SPAN_KEY), 'name' => 'Span Day', 'formula' => '[DIM_SPANS/Span Day]' }] }
  fact = { 'id' => 'el-fact', 'kind' => 'table',
           'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS PUBLIC FACT_STAYS] },
           'columns' => [
             { 'id' => 'inode-f0/STAY_ID~x', 'name' => 'Stay Id', 'formula' => '[FACT_STAYS/Stay Id]' },
             { 'id' => inode('f1', FK_ADMIT), 'name' => 'Admit Date Key', 'formula' => '[FACT_STAYS/Admit Date Key]' },
             { 'id' => inode('f2', FK_DISCHARGE), 'name' => 'Discharge Date Key', 'formula' => '[FACT_STAYS/Discharge Date Key]' },
             { 'id' => 'inode-f3/STAY_REVENUE~x', 'name' => 'Stay Revenue', 'formula' => '[FACT_STAYS/Stay Revenue]' }
           ],
           'order' => [],
           'relationships' => [
             { 'id' => 'r-admit', 'name' => 'DIM_DATES (Admit Date)', 'targetElementId' => 'el-admit',
               'keys' => [{ 'sourceColumnId' => inode('f1', FK_ADMIT), 'targetColumnId' => inode('a1', DIM_KEY) }] },
             { 'id' => 'r-discharge', 'name' => 'DIM_DATES (Discharge Date)', 'targetElementId' => 'el-discharge',
               'keys' => [{ 'sourceColumnId' => inode('f2', FK_DISCHARGE), 'targetColumnId' => inode('b1', DIM_KEY) }] }
           ] }
  derived = { 'id' => 'el-derived', 'kind' => 'table', 'name' => 'Fact Stays View',
              'source' => { 'kind' => 'table', 'elementId' => 'el-fact' },
              'columns' => [{ 'id' => 'dv1', 'formula' => '[FACT_STAYS/Stay Revenue]' }], 'order' => ['dv1'] }
  { 'pages' => [{ 'id' => 'p1', 'elements' => [admit, discharge, spans, fact, derived] }] }
end

# .twb fragment: Followup Date role joins DATE([SRC_FOLLOWUP]) = [SPAN_KEY],
# second end-point is the Followup Date object (structural role identity).
TWB = <<~XML
  <workbook>
    <column caption='Followup Date' datatype='date' name='[#{SRC_FOLLOWUP}]' />
    <object-graph>
      <objects>
        <object caption='FACT_STAYS' id='#{FACT_OBJ}' />
        <object caption='Followup Date' id='#{SPAN_OBJ}' />
      </objects>
      <relationships>
        <relationship>
          <expression op='='><expression op='DATE([#{SRC_FOLLOWUP}])'/><expression op='[#{SPAN_KEY}]'/></expression>
          <first-end-point object-id='#{FACT_OBJ}' />
          <second-end-point object-id='#{SPAN_OBJ}' unique-key='true' />
        </relationship>
      </relationships>
    </object-graph>
  </workbook>
XML

REAL_COLS = {
  'FACT_STAYS' => %w[STAY_ID ADMIT_DATE_KEY DISCHARGE_DATE_KEY FOLLOWUP_DATE_KEY STAY_REVENUE],
  'DIM_DATES'  => %w[DATE_KEY DATE_DAY DATE_MONTH],
  'DIM_SPANS'  => %w[SPAN_LABEL] # verifiably MISSING the span key column
}.freeze
CATALOGS = { 'DIM_DATES' => [{ 'name' => 'DATE_DAY', 'type' => 'date' }] }.freeze

def fact_of(model)
  model['pages'].flat_map { |p| p['elements'] }.find { |e| e['id'] == 'el-fact' }
end

def els_of(model)
  model['pages'].flat_map { |p| p['elements'] }
end

# ---------------------------------------------------------------------------
puts 'Part 1 — physical-FK recovery creates a NEW per-role instance (never a second rel onto another role)'
m = base_model
msgs = MechanicalSpecs.recover_computed_key_joins!(m, TWB, REAL_COLS, CATALOGS)
fact = fact_of(m)
new_rel = (fact['relationships'] || []).find { |r| r['name'] == 'DIM_DATES (Followup Date)' }
inst = els_of(m).find { |e| e['name'] == 'DIM_DATES (Followup Date)' }
check(msgs.any? { |x| x =~ /NEW role instance/ }, "recovery announces the new role instance (got #{msgs.inspect})", fails)
check(!inst.nil?, 'a NEW element instance of the date view exists for the role', fails)
check(new_rel && new_rel['targetElementId'] == inst&.dig('id'),
      'the role relationship targets the NEW instance (not Admit/Discharge)', fails)
check(new_rel && (fact['columns'] || []).any? { |c| c['id'] == new_rel.dig('keys', 0, 'sourceColumnId') && c['name'] == 'Followup Date Key' },
      "role relationship keys on the fact's own Followup Date Key FK", fails)
tgt_counts = (fact['relationships'] || []).group_by { |r| r['targetElementId'] }.values.map(&:size)
check(tgt_counts.all? { |n| n == 1 }, 'every fact relationship targets a DISTINCT element (no compounding)', fails)
check(MechanicalSpecs.relationship_reachability_violations(m).empty?, 'recovered model passes the reachability guard', fails)
drv = els_of(m).find { |e| e['id'] == 'el-derived' }
check((drv['columns'] || []).any? { |c| c['name'] == 'Followup Date' && c['formula'].include?('DIM_DATES (Followup Date)') },
      'derived view gains the role-named date payload column', fails)

puts 'Part 2 — idempotence: re-running the recovery adds nothing'
before = JSON.generate(m)
msgs2 = MechanicalSpecs.recover_computed_key_joins!(m, TWB, REAL_COLS, CATALOGS)
check(msgs2.any? { |x| x =~ /already wired/ }, "second run reports already-wired (got #{msgs2.inspect})", fails)
check(JSON.generate(m) == before, 'second run leaves the model byte-identical', fails)

puts 'Part 3 — ambiguous physical date view: REFUSE with a GAP, wire nothing'
m3 = base_model(discharge_path: %w[ANALYTICS PUBLIC DIM_DATES_ALT])
n_before = els_of(m3).size
msgs3 = MechanicalSpecs.recover_computed_key_joins!(m3, TWB, REAL_COLS, CATALOGS)
check(msgs3.any? { |x| x =~ /\AGAP:/ && x =~ /candidate physical date view/ },
      "ambiguous views refuse with GAP (got #{msgs3.inspect})", fails)
check(els_of(m3).size == n_before && (fact_of(m3)['relationships'] || []).size == 2,
      'ambiguous views: no element and no relationship added', fails)

puts 'Part 4 — compound-risk target: REFUSE (never a second rel onto an occupied element)'
# Point the computed join's target guid at the ADMIT instance's shared key —
# with two instances owning it and a role caption matching neither uniquely,
# attribution is ambiguous and must refuse.
twb4 = TWB.gsub(SPAN_KEY, DIM_KEY)
m4 = base_model
msgs4 = MechanicalSpecs.recover_computed_key_joins!(m4, twb4, REAL_COLS, CATALOGS)
check(msgs4.any? { |x| x =~ /\AGAP:/ && x =~ /role instances/ },
      "shared-guid multi-instance target refuses with GAP (got #{msgs4.inspect})", fails)
check((fact_of(m4)['relationships'] || []).size == 2, 'no relationship was added onto an existing role instance', fails)

puts 'Part 5 — calc-key path wires to the guid OWNER element (own instance)'
m5 = base_model
# Fact carries the wrapped column; DIM_SPANS' view now really has the key.
f5 = fact_of(m5)
f5['columns'] << { 'id' => inode('f9', SRC_FOLLOWUP), 'name' => 'Followup Date', 'formula' => '[FACT_STAYS/Followup Date]' }
rc5 = REAL_COLS.merge('DIM_SPANS' => %w[SPAN_DAY SPAN_LABEL])
msgs5 = MechanicalSpecs.recover_computed_key_joins!(m5, TWB, rc5, CATALOGS)
rel5 = (fact_of(m5)['relationships'] || []).find { |r| r['targetElementId'] == 'el-spans' }
key5 = (fact_of(m5)['columns'] || []).find { |c| c['id'] == 'c-followup-date-join-key' }
check(msgs5.any? { |x| x =~ /calc key, own instance/ }, "calc-key recovery announced (got #{msgs5.inspect})", fails)
check(rel5 && key5 && key5['formula'] == 'Date([Followup Date])' &&
      rel5.dig('keys', 0, 'sourceColumnId') == key5['id'],
      'relationship keys on the synthesized Date([Followup Date]) calc column into the owner element', fails)

puts 'Part 6 — reachability guard flags two relationships onto ONE target element'
m6 = base_model
fact_of(m6)['relationships'] << { 'id' => 'r-bad', 'name' => 'DIM_DATES (Bad Clone)', 'targetElementId' => 'el-admit',
                                  'keys' => [{ 'sourceColumnId' => inode('f2', FK_DISCHARGE),
                                               'targetColumnId' => inode('a1', DIM_KEY) }] }
viols = MechanicalSpecs.relationship_reachability_violations(m6)
check(viols.any? { |v| v =~ /target the SAME element/ && v =~ /own element instance/ },
      "same-target compounding is a loud violation (got #{viols.inspect})", fails)

puts
if fails.empty?
  puts 'OK — role-instance recovery locked (6 parts)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
