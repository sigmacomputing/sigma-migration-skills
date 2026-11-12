#!/usr/bin/env ruby
# frozen_string_literal: true

# record-blind-grade.rb — record <WORK>/blind-grade.json through the shared
# record-visual-check.rb, without the two traps the live re-proof hit:
#
#   * --screenshot defaults to the LATEST budgeted RCF render from
#     fidelity-ledger.json (record-visual-check requires it whenever the ledger
#     exists, and refused the grade when it was omitted);
#   * a REFUSED grade is archived to blind-grade.refused-<n>.json (+ the
#     reason in blind-grade-refusals.jsonl), so a leftover refused grade can
#     never keep the finalize preflight blocked. The next step is printed.
#
#   ruby scripts/record-blind-grade.rb --workdir <WORK> [--verdict pass|divergent]
#        [--blind-grade FILE] [--screenshot PNG] [--notes "..."] [--checklist "k=pass,..."] [--agent-vision true|false]
#
# --verdict/--checklist are omitted for a v2 grade (the verdict is computed from it).
#
# Exit: record-visual-check's own status (0 recorded).

require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
$LOAD_PATH.unshift File.join(__dir__, 'lib')
require 'finalize_preflight'

opts = { vision: 'true' }
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:dir] = v }
  p.on('--verdict V') { |v| opts[:verdict] = v }
  p.on('--blind-grade F') { |v| opts[:grade] = v }
  p.on('--screenshot P') { |v| opts[:shot] = v }
  p.on('--notes S') { |v| opts[:notes] = v }
  p.on('--checklist S') { |v| opts[:checklist] = v }
  p.on('--agent-vision B') { |v| opts[:vision] = v }
end.parse!
abort('usage: record-blind-grade.rb --workdir DIR [--verdict pass|divergent] [...]') unless opts[:dir]

dir = opts[:dir]
grade = opts[:grade] || File.join(dir, 'blind-grade.json')
abort("no #{grade} — run the context-free grader first (refs/blind-grader-brief.md)") unless File.file?(grade)
shot = opts[:shot] || FinalizePreflight.latest_render(dir)&.fetch('path', nil)

cmd = [RbConfig.ruby, File.join(__dir__, 'record-visual-check.rb'), '--workdir', dir,
       '--blind-grade', grade, '--agent-vision', opts[:vision]]
cmd += ['--verdict', opts[:verdict]] if opts[:verdict]
cmd += ['--screenshot', shot] if shot
cmd += ['--notes', opts[:notes]] if opts[:notes]
cmd += ['--checklist', opts[:checklist]] if opts[:checklist]
out, st = Open3.capture2e(*cmd)
print out
exit 0 if st.success?
exit st.exitstatus unless out.match?(/(?:\A|\n)REFUSED:/)

# Refused: archive the grade (never leave it to block the preflight).
n = Dir[File.join(dir, 'blind-grade.refused-*.json')].size + 1
arch = File.join(dir, "blind-grade.refused-#{n}.json")
File.rename(grade, arch)
reason = out.lines.grep(/REFUSED|FATAL|mismatch|census/i).first(3).map(&:strip).join(' | ')
reason = out.lines.last(2).map(&:strip).join(' | ') if reason.empty?
File.open(File.join(dir, 'blind-grade-refusals.jsonl'), 'a') do |f|
  f.puts(JSON.generate('n' => n, 'archived' => arch, 'exit' => st.exitstatus, 'reason' => reason,
                       'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
end
warn "REFUSED grade archived → #{arch} (reason: #{reason})"
warn 'Next: re-grade the latest render with a FRESH context-free grader (writes blind-grade.json) and re-run this,'
warn "  or record the gap without a grade: ruby scripts/record-visual-check.rb --workdir #{dir} --verdict divergent " \
     "--notes \"<gap>; blind grade refused: see blind-grade-refusals.jsonl\" --agent-vision #{opts[:vision]}" \
     "#{shot ? " --screenshot #{shot}" : ''}"
exit st.exitstatus
