# frozen_string_literal: true

# Extraction notes that mean data or fidelity was LOST, read back out of the TMSL on every route
# (--pbix, --tmsl, a cached rerun): Enter-data cells loaded as NULL (an unparseable date, a value
# that does not fit its column type), Enter-data SQL not generated for an unsupported warehouse,
# and an ASSUMED model culture (pbixray did not expose the real one). extract-model-pbix.py records
# them as model.bim annotations; before this module nothing read them, so a column that loaded as
# all-NULL was only visible to someone opening model.bim.
#
# Ruby 2.6 floor.
module PbiExtractNotes
  module_function

  CULTURE_ASSUMED = 'SigmaMigration.CultureAssumed'
  LOSS_PREFIXES = ['Enter data:', 'Enter-data SQL NOT generated', 'Table.FromRows rows could not be decoded'].freeze

  # [{ 'where' => 'model' | table name, 'kind' => 'culture-assumed' | 'enter-data', 'note' => text }]
  def collect(tmsl)
    m = tmsl.is_a?(Hash) && tmsl['model'].is_a?(Hash) ? tmsl['model'] : (tmsl || {})
    out = []
    (m['annotations'] || []).each do |a|
      out << { 'where' => 'model', 'kind' => 'culture-assumed', 'note' => a['value'].to_s } if a['name'] == CULTURE_ASSUMED
    end
    (m['tables'] || []).each do |t|
      (t['annotations'] || []).each do |a|
        v = a['value'].to_s
        next unless a['name'].to_s.start_with?('SigmaMigration.ExtractNote')
        next unless LOSS_PREFIXES.any? { |p| v.start_with?(p) }

        out << { 'where' => t['name'].to_s, 'kind' => 'enter-data', 'note' => v }
      end
    end
    out
  end

  def lines(notes, limit = 12)
    out = notes.first(limit).map { |n| "⚠ extract: #{n['where']}: #{n['note']}" }
    out << "⚠ extract: ... and #{notes.size - limit} more (see extract-notes.json)" if notes.size > limit
    out
  end
end
