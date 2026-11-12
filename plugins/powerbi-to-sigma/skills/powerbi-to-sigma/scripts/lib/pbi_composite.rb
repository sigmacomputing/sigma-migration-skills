# frozen_string_literal: true

# Detect Fabric-extracted models that are incomplete because they reference a
# remote Power BI / Analysis Services semantic model.
#
# Storage mode is deliberately NOT a signal: a DirectQuery partition over a
# warehouse connector (Snowflake.Databases, Sql.Database, ...) is ordinary and
# fully convertible. NativeQuery is ordinary warehouse SQL and is not a signal
# either. Only references to ANOTHER Power BI / AS model trip the gate:
#   - an M expression (partition or shared) naming a remote-model connector;
#   - an 'entity' partition (DirectQuery-over-AS proxy table);
#   - a partition whose expressionSource names a shared expression that
#     connects to a remote model.
module PbiComposite
  module_function

  REMOTE_CONNECTOR = %r{AnalysisServices\.Database|PowerBIServiceLive|DirectQueryToAS|pbiazure|PowerBI\.Datasets|powerbi://}i

  def incomplete_reasons(model)
    shared = shared_expressions(model)
    reasons = []
    (model['tables'] || []).each do |table|
      name = table['name']
      next if name.to_s.start_with?('LocalDateTable_', 'DateTableTemplate_')

      Array(table['partitions']).each do |partition|
        source = partition['source'] || {}
        expression_source = source['expressionSource'].to_s
        remote_source = !expression_source.empty? && remote?(shared[expression_source])
        if source['type'].to_s.downcase == 'entity'
          detail = remote_source ? " via expressionSource '#{expression_source}'" : ''
          reasons << "table '#{name}' is an 'entity' partition bound to a remote model#{detail}"
        elsif remote_source
          reasons << "table '#{name}' expressionSource '#{expression_source}' references a remote Power BI dataset"
        end
        if remote?(source['expression'])
          reasons << "table '#{name}' M expression references a remote Power BI dataset"
        end
      end
    end
    shared.each do |expr_name, expression|
      reasons << "shared expression '#{expr_name}' references a remote Power BI dataset" if remote?(expression)
    end
    reasons.uniq
  end

  def shared_expressions(model)
    Array(model['expressions']).each_with_object({}) do |expr, acc|
      acc[expr['name'].to_s] = expr['expression'] if expr.is_a?(Hash) && expr['name']
    end
  end

  def remote?(expression)
    expression = expression.join("\n") if expression.is_a?(Array)
    expression.is_a?(String) && expression.match?(REMOTE_CONNECTOR)
  end
end
