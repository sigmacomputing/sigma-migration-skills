# frozen_string_literal: true

require_relative 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'

module Sigma
  module WorkbookSql
    module_function

    def findings(response, workbook_id:, workbook_name:)
      doc = CodeRep.document(response)
      return [] unless doc['elements'].is_a?(Array)

      folder_id = CodeRep.metadata(response)['folderId']
      doc['elements'].filter_map do |element|
        source = element['source']
        next unless source.is_a?(Hash) && source['kind'] == 'sql'

        element_name = element['name'].to_s.strip
        element_name = "#{workbook_name} SQL" if element_name.empty?
        {
          workbook_id: workbook_id,
          workbook_name: workbook_name,
          folder_id: folder_id,
          element_id: element['id'],
          element_name: element_name,
          connection_id: source['connectionId'],
          sql: source['statement'],
          column_count: Array(element['columns']).length
        }
      end
    end
  end
end
