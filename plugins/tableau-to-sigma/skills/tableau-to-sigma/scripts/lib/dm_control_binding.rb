# frozen_string_literal: true
#
# Bind workbook controls to controls in a sourced Sigma data model.
#
# A workbook formula can reference only a WORKBOOK control by [controlId].
# Reusing the same text as a data-model controlId does not cross the document
# boundary. Sigma's explicit bridge is the workbook control's `parameters[]`:
#   {kind:"data-model", dataModelId:"...", controlId:"<DM control id>"}
#
# The Tableau converter emits parameter controls into the DM, while the chart
# builder emits the interactive workbook controls. This helper joins those two
# artifacts by stable Tableau caption/controlId and adds the bridge.

module DmControlBinding
  module_function

  PREFIX_RE = /\Actl-(?:param|parameter)-/i

  def norm(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def keys(control, workbook: false)
    values = [control['controlId'], control['name']]
    values << control['controlId'].to_s.sub(PREFIX_RE, '') if workbook
    values.map { |value| norm(value) }.reject(&:empty?).uniq
  end

  def workbook_controls(spec)
    document = spec.is_a?(Hash) && spec['document'].is_a?(Hash) ? spec['document'] : spec
    elements = if document.is_a?(Hash) && document['elements'].is_a?(Array)
                 document['elements']
               else
                 Array(document && document['pages']).flat_map { |page| Array(page['elements']) }
               end
    elements.select { |element| element.is_a?(Hash) && element['kind'] == 'control' }
  end

  # Mutates `spec`. DM controls must come from the POST/GET readback census, not
  # the authored request, so a stripped/rejected control can never be targeted.
  # Returns an audit hash with bound, unmatched, and ambiguous workbook controls.
  def bind!(spec, data_model_id:, data_model_elements:)
    dm_controls = Array(data_model_elements).select do |element|
      element.is_a?(Hash) && element['kind'] == 'control' &&
        !element['controlId'].to_s.empty?
    end
    index = Hash.new { |hash, key| hash[key] = [] }
    dm_controls.each { |control| keys(control).each { |key| index[key] << control } }

    result = { bound: [], unmatched: [], ambiguous: [] }
    workbook_controls(spec).each do |control|
      candidates = keys(control, workbook: true).flat_map { |key| index[key] }.uniq
      label = control['name'] || control['controlId'] || control['id']
      if candidates.empty?
        result[:unmatched] << label
        next
      end
      if candidates.length > 1
        result[:ambiguous] << {
          'workbook_control' => label,
          'data_model_controls' => candidates.map { |candidate| candidate['controlId'] }
        }
        next
      end

      target = {
        'kind' => 'data-model',
        'dataModelId' => data_model_id,
        'controlId' => candidates.first['controlId']
      }
      control['parameters'] ||= []
      unless control['parameters'].any? do |parameter|
               parameter.is_a?(Hash) &&
                 parameter['kind'] == target['kind'] &&
                 parameter['dataModelId'] == target['dataModelId'] &&
                 parameter['controlId'] == target['controlId']
             end
        control['parameters'] << target
      end
      result[:bound] << {
        'workbook_control' => label,
        'workbook_control_id' => control['controlId'],
        'data_model_control_id' => target['controlId']
      }
    end
    result
  end
end
