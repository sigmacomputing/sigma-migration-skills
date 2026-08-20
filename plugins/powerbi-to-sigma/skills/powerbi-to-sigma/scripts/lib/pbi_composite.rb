# frozen_string_literal: true

# Detect Fabric-extracted models that are incomplete because they reference a
# remote Power BI / Analysis Services semantic model. NativeQuery is ordinary
# warehouse SQL and deliberately is not a composite signal.
module PbiComposite
  module_function

  REMOTE_CONNECTOR = /AnalysisServices\.Database|PowerBIServiceLive|DirectQueryToAS|pbiazure|PowerBI\.Datasets/i

  def incomplete_reasons(model)
    reasons = []
    (model['tables'] || []).each do |table|
      name = table['name']
      next if name.to_s.start_with?('LocalDateTable_', 'DateTableTemplate_')

      Array(table['partitions']).each do |partition|
        mode = partition['mode'].to_s.downcase
        reasons << "table '#{name}' has a DirectQuery partition" if mode == 'directquery'
        source = partition['source'] || {}
        reasons << "table '#{name}' is an 'entity' partition bound to a remote model" \
          if source['type'].to_s.downcase == 'entity'
        expression = source['expression']
        expression = expression.join("\n") if expression.is_a?(Array)
        if expression.is_a?(String) && expression.match?(REMOTE_CONNECTOR)
          reasons << "table '#{name}' M expression references a remote Power BI dataset"
        end
      end
    end
    reasons.uniq
  end
end
