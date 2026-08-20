#!/usr/bin/env ruby
# frozen_string_literal: true
#
# new-skill.rb — scaffold a new <tool>-to-sigma converter + <tool>-assessment.
#
#   ruby tools/new-skill.rb <tool> ["Display Name"]
#   ruby tools/new-skill.rb sisense "Sisense"
#
# Produces a skeleton that already passes the governance gates:
#   - converter + assessment skill dirs with SKILL.md (every mandatory arc gate
#     documented, so tools/lint-skills.rb is green)
#   - the core shared infra synced in AND registered in shared/manifest.json
#     (so tools/check-shared.rb covers it)
#   - a docs/phase-schema.md section (so the coverage check is green)
#   - plugin.json + marketplace.json entry + AGENTS.md index rows (scaffold
#     maturity when that column exists)
# Remaining human TODOs: corpus case + real SKILL.md prose + marketplace blurb.
#
# Creds-free, stdlib-only.

require 'json'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

tool = ARGV[0]
abort "usage: ruby tools/new-skill.rb <tool> [\"Display Name\"]" if tool.nil? || tool.empty?
abort "tool must be lowercase letters/digits/hyphens (e.g. 'sisense')" unless tool.match?(/\A[a-z0-9][a-z0-9-]*\z/)
display = ARGV[1] || tool.split('-').map(&:capitalize).join(' ')

plugin   = "plugins/#{tool}-to-sigma"
conv_dir = "#{plugin}/skills/#{tool}-to-sigma"
asmt_dir = "#{plugin}/skills/#{tool}-assessment"
abort "#{plugin} already exists — refusing to overwrite." if Dir.exist?(plugin)

# --- core shared infra a new converter / assessment should vendor ----------
CONV_SHARED = %w[
  shared/lib/sigma_rest.rb shared/lib/preflight_lint.rb shared/lib/layout_lint.rb
  shared/lib/control_lint.rb shared/scripts/escalate-gap.py shared/scripts/probe-controls.rb
  shared/scripts/find-or-pick-dm.rb shared/scripts/assert-phase6-ran.rb
  shared/scripts/get-token.sh shared/scripts/sigma-export-png.py
].freeze
ASMT_SHARED = %w[shared/assessment/dup-dashboards.py].freeze

def target_for(canonical, skill_dir)
  case canonical
  when %r{\Ashared/lib/(.+)\z}      then "#{skill_dir}/scripts/lib/#{$1}"
  when %r{\Ashared/scripts/(.+)\z}  then "#{skill_dir}/scripts/#{$1}"
  when %r{\Ashared/assessment/(.+)\z} then "#{skill_dir}/scripts/#{$1}"
  else abort "unmapped canonical: #{canonical}"
  end
end

[conv_dir, asmt_dir].each { |d| FileUtils.mkdir_p("#{d}/scripts/lib"); FileUtils.mkdir_p("#{d}/refs") }

# --- 1. sync shared infra into the new skills ------------------------------
synced = []
(CONV_SHARED.map { |c| [c, conv_dir] } + ASMT_SHARED.map { |c| [c, asmt_dir] }).each do |canonical, dir|
  abort "missing canonical #{canonical} — run from repo root" unless File.exist?(canonical)
  t = target_for(canonical, dir)
  FileUtils.mkdir_p(File.dirname(t))
  FileUtils.cp(canonical, t)
  File.chmod(File.stat(canonical).mode, t)
  synced << [canonical, t]
end

# --- 2. register the new copies as targets in shared/manifest.json ---------
manifest = JSON.parse(File.read('shared/manifest.json'))
by_canon = manifest['shared'].each_with_object({}) { |e, h| h[e['canonical']] = e }
synced.each do |canonical, t|
  entry = by_canon[canonical] or next
  next if entry['targets'].any? { |x| (x.is_a?(Hash) ? x['path'] : x) == t }
  entry['targets'] << t
end
File.write('shared/manifest.json', JSON.pretty_generate(manifest) + "\n")

# --- 3. converter SKILL.md skeleton (documents every mandatory gate) -------
File.write("#{conv_dir}/SKILL.md", <<~MD)
  ---
  name: #{tool}-to-sigma
  description: Convert a #{display} model + dashboards into a Sigma data model and matching workbook. Discovery, calc translation, DM + workbook creation via REST, layout, and warehouse parity verification.
  ---

  # #{display} → Sigma

  > SCAFFOLD — fill every TODO before first live run. Phase numbering is local to
  > this skill; the canonical Assess→Discover→Reuse→Convert→Post-DM→Build→Layout→
  > Parity→Security→Enhance arc and this skill's mapping live in
  > `docs/phase-schema.md` (full clone only). Add this skill's column there.

  ## Phase 0 — Assess (C1)
  TODO: feature-gap scan + scope. Defer tenant inventory to the `#{tool}-assessment` skill.

  ## Phase 1 — Discover (C2)
  TODO: pull the #{display} model + dashboard/report definitions and the warehouse columns.

  ## Phase 1.5 — Reuse-check (C3)
  Before creating a DM, score existing Sigma DMs and reuse on a strong match
  (avoid sprawl). Mirrors tableau Phase 1.5:
  `ruby scripts/find-or-pick-dm.rb --workbook-signature <sig.json>`.

  ## Phase 2 — Convert (C4)
  TODO: #{display} model → Sigma data-model JSON.

  ## Phase 3 — Post the data model + read back (C5)  ← HARD GATE
  POST the DM, then **read back** the real element/column ids and wire the
  workbook to those — never to client-side ids: `ruby scripts/post-and-readback.rb`.

  ## Phase 4 — Build the workbook (C6)
  TODO: dashboards → Sigma workbook spec wired to the read-back ids.

  ## Phase 5 — Layout (C7)
  Apply the grid layout as the **LAST write** (a bare spec PUT wipes layout):
  `ruby scripts/put-layout.rb --workbook <id> --layout layout.xml`. Then run the
  visual-QA PNG check (`scripts/sigma-export-png.py`); see
  `refs/layout-visual-qa.md`.

  ## Phase 6 — Verify parity (C8)  ← HARD GATE, never skip
  Compare #{display} values vs Sigma (vs warehouse where possible). Gated by
  `scripts/assert-phase6-ran.rb`. A migration is not done until parity is GREEN.

  ## Security: RLS / CLS (C9)
  Detect #{display} row-level/column-level security always; apply to Sigma
  user-attributes + DM filters opt-in. TODO: document the #{display} mechanism.

  ## Gaps
  Unsupported source features → `python3 scripts/escalate-gap.py` (opt-in issue filer). Never fake a feature; flag it.
MD

File.write("#{conv_dir}/QUICKSTART.md", "# #{display} → Sigma — Quickstart\n\nTODO: minimal end-to-end example. Auth: `eval \"$(scripts/get-token.sh)\"`.\n")
File.write("#{conv_dir}/refs/layout-visual-qa.md", "# Visual QA (#{display})\n\nTODO: render each page to PNG via scripts/sigma-export-png.py and compare to source.\n")

# --- 4. assessment SKILL.md skeleton ---------------------------------------
File.write("#{asmt_dir}/SKILL.md", <<~MD)
  ---
  name: #{tool}-assessment
  description: Inventory a #{display} instance and produce a migration-readiness readout — environment counts, content mix, complexity, and a value/cost-ranked shortlist. Read-only.
  ---

  # #{display} migration assessment (read-only)

  > SCAFFOLD. Assessments never write to the source or post to Sigma. Produce the
  > standard readout (see other `*-assessment` skills) and hand off to
  > `#{tool}-to-sigma`.

  ## Phase 0 — Connect
  TODO: auth to #{display} (read-only).

  ## Phase 1 — Inventory
  TODO: enumerate dashboards/models/users; dedup with `scripts/dup-dashboards.py`.

  ## Phase 2 — Score + shortlist
  TODO: complexity score + value/cost-ranked migration shortlist + readout.
MD

# --- 5. phase-schema.md coverage section -----------------------------------
File.open('docs/phase-schema.md', 'a') do |f|
  f.puts
  f.puts "## #{tool}-to-sigma (scaffolded — fill in)"
  f.puts
  f.puts "TODO: map this skill's local phase numbers to C1–C10 (and add it as a"
  f.puts "column to the mapping table above). Generated by tools/new-skill.rb."
end

# --- 6. plugin.json (marketplace-installable unit) -------------------------
plugin_json_dir = "#{plugin}/.claude-plugin"
FileUtils.mkdir_p(plugin_json_dir)
plugin_name = "#{tool}-to-sigma"
File.write("#{plugin_json_dir}/plugin.json", JSON.pretty_generate({
  '$schema' => 'https://json.schemastore.org/claude-code-plugin-manifest.json',
  'name' => plugin_name,
  'displayName' => "#{display} → Sigma",
  'version' => '0.1.0',
  'description' => "Migrate #{display} content to Sigma — converter + assessment (scaffolded). Bundles #{tool}-to-sigma + #{tool}-assessment.",
  'author' => { 'name' => 'Sigma Computing' },
  'license' => 'MIT',
  'keywords' => [tool, 'sigma', 'migration', 'bi', 'converter'],
  'skills' => './skills/'
}) + "\n")

# --- 7. marketplace.json entry (surgical append — don't reformat the file) --
marketplace_path = '.claude-plugin/marketplace.json'
marketplace_body = File.read(marketplace_path)
unless marketplace_body.include?("\"name\": \"#{plugin_name}\"")
  entry = <<~JSON.chomp
    ,
        {
          "name": "#{plugin_name}",
          "source": "./plugins/#{plugin_name}",
          "description": "#{display} → Sigma (scaffolded). Bundles #{tool}-to-sigma + #{tool}-assessment.",
          "category": "migration",
          "keywords": ["#{tool}", "migration", "bi"]
        }
  JSON
  # Insert before the closing of the plugins array: final `  ]` after the last
  # plugin object. Match the last `  ]` that closes "plugins".
  replaced = marketplace_body.sub(%r{\n  \]\n\}}m) { "#{entry}\n  ]\n}" }
  abort 'marketplace.json: could not find plugins-array close to append to' if replaced == marketplace_body
  File.write(marketplace_path, replaced)
end

# --- 8. AGENTS.md skill-index rows -----------------------------------------
agents_path = 'AGENTS.md'
agents = File.read(agents_path)
conv_skill = "#{tool}-to-sigma"
asmt_skill = "#{tool}-assessment"
unless agents.include?("`#{conv_skill}`")
  # Detect maturity column (added by the agent-entry-contract docs PR).
  header = agents.lines.find { |l| l.start_with?('| Intent |') } || ''
  has_maturity = header.include?('| Maturity |')
  conv_row = if has_maturity
    "| Convert a #{display} model + dashboards → Sigma | `#{conv_skill}` | scaffold | `plugins/#{plugin_name}/skills/#{conv_skill}/` |"
  else
    "| Convert a #{display} model + dashboards → Sigma | `#{conv_skill}` | `plugins/#{plugin_name}/skills/#{conv_skill}/` |"
  end
  asmt_row = if has_maturity
    "| Scope/assess a #{display} instance | `#{asmt_skill}` | scaffold | `plugins/#{plugin_name}/skills/#{asmt_skill}/` |"
  else
    "| Scope/assess a #{display} instance | `#{asmt_skill}` | `plugins/#{plugin_name}/skills/#{asmt_skill}/` |"
  end
  # Insert before the blank line that follows the table (after the last | row
  # in the Skill index section).
  lines = agents.lines
  idx = lines.rindex { |l| l.start_with?('| ') && l.include?('plugins/') }
  abort 'AGENTS.md: could not find skill-index table to append to' unless idx
  lines.insert(idx + 1, conv_row + "\n", asmt_row + "\n")
  File.write(agents_path, lines.join)
end

puts "Scaffolded #{plugin}:"
puts "  converter:  #{conv_dir}/SKILL.md"
puts "  assessment: #{asmt_dir}/SKILL.md"
puts "  plugin.json + marketplace entry + AGENTS.md index rows"
puts "  synced #{synced.size} shared files (registered in shared/manifest.json)"
puts "  appended a docs/phase-schema.md coverage section"
puts
puts "Verify green:  ruby tools/check-shared.rb && ruby tools/lint-skills.rb"
puts
puts "Still TODO (human):"
puts "  1. Add a corpus case under corpus/#{tool}/<case>/ (source + golden) — see corpus/README.md."
puts "  2. Fill every TODO in the two SKILL.md files."
puts "  3. Replace the scaffold marketplace description with a real blurb before release."
