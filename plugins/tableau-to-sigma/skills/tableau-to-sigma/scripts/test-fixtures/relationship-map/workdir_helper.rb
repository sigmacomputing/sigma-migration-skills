# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative '../../lib/relationship_map'

# Test helper: a workdir on the reused-DM evidence route, built from one
# fixture case. probe: true marks every map edge proven; parity: worksheet
# names that passed Phase 6 (nil = no parity-final.json).
module RelationshipMapWorkdir
  PROVEN = { 'status' => 'pass', 'unique' => { 'total' => 5, 'distinct' => 5 }, 'unmatched' => 0 }.freeze

  module_function

  def build(work, fixture, probe: true, parity: nil, route: true)
    src = File.join(__dir__, fixture)
    %w[workbook-content.twb dm-spec-reused.json dashboard-scope.json].each { |f| FileUtils.cp(File.join(src, f), work) }
    map = RelationshipMap.derive(
      twb_xml: File.read(File.join(work, 'workbook-content.twb'), encoding: 'bom|utf-8'),
      dm_spec: JSON.parse(File.read(File.join(work, 'dm-spec-reused.json'))),
      dashboards: RelationshipMap.scoped_dashboards(JSON.parse(File.read(File.join(work, 'dashboard-scope.json'))))
    )
    map['dm_edges'].each { |d| d['probe'] = PROVEN.dup } if probe
    RelationshipMap.write(File.join(work, 'relationship-map.json'), map)
    if parity
      File.write(File.join(work, 'parity-final.json'),
                 JSON.generate('status' => 'PASS', 'pass_names' => parity, 'fail_names' => []))
    end
    state = if route
              { 'relationship_route' => 'reused-dm-evidence', 'reused_dm' => true, 'data_model_id' => 'dm-reused' }
            else
              { 'route' => 'orchestrated' }
            end
    File.write(File.join(work, 'migrate-state.json'), JSON.generate(state))
    map
  end
end
