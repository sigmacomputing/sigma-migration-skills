# frozen_string_literal: true

# Tableau-specific workbook code-representation helpers.
#
# Workbook elements are document-global. Page membership is encoded only by the
# document.layout XML; document.pages contains metadata. Data-model specs do NOT
# use this adapter and keep their nested pages[].elements shape.
require 'cgi'
require_relative 'code_rep'

module WorkbookCode
  module_function

  GRID_COLUMNS = 24
  LEGACY_DOCUMENT_KEY = '__workbook_code_original_document'
  LEGACY_METADATA_KEY = '__workbook_code_original_metadata'

  def document(spec)
    Sigma::CodeRep.document(spec)
  end

  def metadata(spec)
    Sigma::CodeRep.metadata(spec)
  end

  def elements(spec)
    doc = document(spec)
    records = Sigma::CodeRep.workbook_elements(doc)
    records = Array(doc['pages']).flat_map { |page| page.is_a?(Hash) ? Array(page['elements']) : [] } if records.empty?
    seen = {}
    records.select { |element| element.is_a?(Hash) }.reject do |element|
      id = element['id']
      duplicate = id && seen[id]
      seen[id] = true if id
      duplicate
    end
  end

  def elements_with_pages(spec)
    doc = document(spec)
    legacy_pages = Array(doc['pages']).select { |page| page.is_a?(Hash) && page.key?('elements') }
    if legacy_pages.any?
      return legacy_pages.flat_map do |page|
        Array(page['elements']).select { |element| element.is_a?(Hash) }
                               .map { |element| [element, page] }
      end
    end

    Sigma::CodeRep.workbook_elements_with_pages(doc)
  end

  def pages(spec)
    Array(document(spec)['pages']).select { |page| page.is_a?(Hash) }
  end

  # Page id => element ids, in layout order. A nested Container,
  # TabbedContainer, or repeated-container still contributes each elementId
  # exactly once.
  def placements(spec)
    layout = document(spec)['layout'].to_s
    out = Hash.new { |hash, key| hash[key] = [] }
    layout.scan(/<Page\b([^>]*)>(.*?)<\/Page>/m) do |attributes, body|
      page_id = attributes[/\bid="([^"]+)"/, 1]
      next unless page_id
      out[page_id].concat(body.scan(/\belementId="([^"]+)"/).flatten)
    end
    out
  end

  def page_element_ids(spec, page_id)
    Sigma::CodeRep.workbook_page_element_ids(document(spec))[page_id.to_s] || []
  end

  def elements_for_page(spec, page_or_id)
    page_id = page_or_id.is_a?(Hash) ? page_or_id['id'] : page_or_id
    page = pages(spec).find { |candidate| candidate['id'].to_s == page_id.to_s }
    return Array(page['elements']).select { |element| element.is_a?(Hash) } if page&.key?('elements')

    # The shared workbook helper recovers page ownership from layout. Keep the
    # legacy nested-page branch above only for pre-release artifacts.
    page_by_element = Sigma::CodeRep.workbook_page_by_element(document(spec))
    by_id = elements(spec).each_with_object({}) { |element, index| index[element['id']] = element }
    page_element_ids(spec, page_id).filter_map { |id| by_id[id] }
      .select { |element| page_by_element[element['id']]&.dig('id').to_s == page_id.to_s }
  end

  # Compatibility view for legacy, in-memory Tableau transforms. Never emit
  # this shape: canonicalize() removes pages[].elements before serialization.
  def legacy_view(spec)
    doc = document(spec)
    view = metadata(spec).merge(doc.reject { |key, _| key == 'elements' })
    view['pages'] = pages(doc).map do |page|
      page_elements = page.key?('elements') ? Array(page['elements']) : elements_for_page(doc, page)
      page.reject { |key, _| key == 'elements' }
          .merge('elements' => page_elements)
    end
    # Retain the exact envelope partitions while legacy transforms work against
    # page-assigned elements. canonicalize() consumes these private snapshots;
    # they are never serialized. This keeps document fields introduced after
    # this plugin shipped from being reclassified as outer metadata or dropped.
    view[LEGACY_DOCUMENT_KEY] = doc
    view[LEGACY_METADATA_KEY] = metadata(spec)
    view
  end

  def row_span(element)
    kind = element['kind'].to_s
    return 1 if kind == 'page-break'
    return 2 if %w[control text divider button navigation progress].include?(kind)
    return 4 if kind == 'kpi-chart'
    return 10 if %w[table pivot-table].include?(kind)
    8
  end

  def page_xml(page_id, page_elements)
    row = 1
    children = page_elements.map do |element|
      height = row_span(element)
      xml = %(  <Element elementId="#{CGI.escapeHTML(element.fetch('id'))}" gridColumn="1 / #{GRID_COLUMNS + 1}" gridRow="#{row} / #{row + height}"/>)
      row += height
      xml
    end
    [
      %(<Page type="grid" gridTemplateColumns="repeat(#{GRID_COLUMNS}, 1fr)" gridTemplateRows="auto" id="#{CGI.escapeHTML(page_id)}">),
      *children,
      '</Page>'
    ].join("\n")
  end

  def layout_for(page_records)
    %(<?xml version="1.0" encoding="utf-8"?>\n) +
      page_records.map { |page, page_elements| page_xml(page.fetch('id'), page_elements) }.join("\n")
  end

  # Preserve an authored layout while adding newly-created elements exactly
  # once to their assigned page. This is used by incremental Tableau appends.
  def complete_layout(layout, page_records)
    xml = layout.to_s.dup
    current = placements('layout' => xml)
    page_records.each do |page, page_elements|
      page_id = page['id'].to_s
      missing = page_elements.reject { |element| current[page_id].include?(element['id']) }
      next if missing.empty?

      page_pattern = /(<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>)(.*?)(<\/Page>)/m
      match = xml.match(page_pattern)
      unless match
        xml << "\n#{page_xml(page_id, page_elements)}"
        next
      end

      row = match[2].scan(/\bgridRow="(?:\d+)\s*\/\s*(\d+)"/).flatten.map(&:to_i).max || 1
      additions = missing.map do |element|
        height = row_span(element)
        line = %(  <Element elementId="#{CGI.escapeHTML(element.fetch('id'))}" gridColumn="1 / #{GRID_COLUMNS + 1}" gridRow="#{row} / #{row + height}"/>)
        row += height
        line
      end.join("\n")
      replacement = "#{match[1]}#{match[2]}\n#{additions}\n#{match[3]}"
      xml.sub!(page_pattern, replacement)
    end
    xml
  end

  # Convert either a legacy flat workbook or a wrapped workbook to the release
  # shape. Existing document fields are retained wholesale. Nested page
  # elements are flattened in page order and pages become metadata-only.
  def canonicalize(spec)
    raise ArgumentError, 'workbook spec must be an object' unless spec.is_a?(Hash)

    original_doc = spec[LEGACY_DOCUMENT_KEY]
    original_metadata = spec[LEGACY_METADATA_KEY]
    if original_doc.is_a?(Hash)
      # Start from the complete original document, including fields unknown to
      # the current CodeRep adapter, then overlay every document field exposed
      # in the compatibility view. Flat elements are deliberately removed:
      # pages[].elements contains the transformed records and must win by id.
      doc = original_doc.dup
      (Sigma::CodeRep::DOC_KEYS + original_doc.keys).uniq.each do |key|
        doc[key] = spec[key] if spec.key?(key)
      end
      doc.delete('elements') unless spec.key?('elements')
      metadata_out = original_metadata.is_a?(Hash) ? original_metadata.dup : {}
      spec.each do |key, value|
        next if [LEGACY_DOCUMENT_KEY, LEGACY_METADATA_KEY].include?(key)
        next if Sigma::CodeRep::DOC_KEYS.include?(key) || original_doc.key?(key)
        metadata_out[key] = value
      end
    else
      doc = document(spec).dup
      metadata_out = metadata(spec)
    end
    page_records = Array(doc['pages']).map do |page|
      next [page, []] unless page.is_a?(Hash)
      [page.reject { |key, _| key == 'elements' }, Array(page['elements'])]
    end

    existing = Array(doc['elements'])
    flattened = []
    seen = {}
    (existing + page_records.flat_map(&:last)).each do |element|
      next unless element.is_a?(Hash)
      id = element['id']
      next if id && seen[id]
      seen[id] = true if id
      flattened << element
    end

    # If the caller already supplied flat elements, recover their page
    # assignment from layout. A one-page legacy artifact without layout is
    # unambiguous; a multi-page flat artifact is not, so leave its elements
    # unplaced and let validate() reject it rather than guessing membership.
    if page_records.all? { |_, page_elements| page_elements.empty? } && existing.any?
      by_id = existing.each_with_object({}) { |element, index| index[element['id']] = element }
      placed = placements(doc)
      if doc['layout'].to_s.strip.empty? && page_records.one?
        page_records.first[1].concat(existing)
      else
        page_records = page_records.map do |page, _|
          [page, placed[page['id']].filter_map { |id| by_id[id] }]
        end
      end
    end

    doc['schemaVersion'] ||= 1
    doc['kind'] ||= 'workbook'
    doc['pages'] = page_records.map(&:first)
    doc['elements'] = flattened
    doc['layout'] =
      if doc['layout'].to_s.strip.empty?
        layout_for(page_records)
      else
        complete_layout(doc['layout'], page_records)
      end

    Sigma::CodeRep.wrap(doc, extra: metadata_out)
  end

  def validate(spec)
    doc = document(spec)
    errors = []
    errors << 'document.schemaVersion is required' unless doc.key?('schemaVersion')
    errors << 'document.kind must be "workbook"' unless doc['kind'] == 'workbook'
    errors << 'document.pages must be an array' unless doc['pages'].is_a?(Array)
    errors << 'document.elements must be an array' unless doc['elements'].is_a?(Array)
    errors << 'document.layout is required' if doc['layout'].to_s.strip.empty?
    Array(doc['pages']).each_with_index do |page, index|
      errors << "document.pages[#{index}] must not contain elements; layout owns page membership" if page.is_a?(Hash) && page.key?('elements')
    end

    element_records = Array(doc['elements']).select { |element| element.is_a?(Hash) }
    element_records.each_with_index do |element, index|
      errors << "document.elements[#{index}].id is required" if element['id'].to_s.empty?
    end
    ids = element_records.filter_map { |element| element['id'] }.reject(&:empty?)
    duplicate_ids = ids.tally.select { |_, count| count > 1 }
    if duplicate_ids.any?
      detail = duplicate_ids.map { |id, count| %(duplicate id "#{id}" (used #{count}x)) }.join(', ')
      errors << "document element ids must be globally unique: #{detail}"
    end

    page_records = pages(doc)
    page_records.each_with_index do |page, index|
      errors << "document.pages[#{index}].id is required" if page['id'].to_s.empty?
    end
    page_ids = page_records.filter_map { |page| page['id'] }.reject(&:empty?)
    duplicate_pages = page_ids.tally.select { |_, count| count > 1 }.keys
    errors << "duplicate document page ids: #{duplicate_pages.join(', ')}" if duplicate_pages.any?

    layout_page_ids = doc['layout'].to_s.scan(/<Page\b[^>]*\bid="([^"]+)"/).flatten
    duplicate_layout_pages = layout_page_ids.tally.select { |_, count| count > 1 }.keys
    errors << "layout defines pages more than once: #{duplicate_layout_pages.join(', ')}" if duplicate_layout_pages.any?
    missing_layout_pages = page_ids - layout_page_ids
    errors << "layout does not define pages: #{missing_layout_pages.join(', ')}" if missing_layout_pages.any?

    placed = placements(doc)
    unknown_pages = placed.keys - page_ids
    errors << "layout references unknown pages: #{unknown_pages.join(', ')}" if unknown_pages.any?
    refs = placed.values.flatten
    duplicate_refs = refs.tally.select { |_, count| count > 1 }
    if duplicate_refs.any?
      page_names = page_records.each_with_object({}) do |page, index|
        index[page['id']] = page['name'] || page['id']
      end
      owners = Hash.new { |hash, key| hash[key] = [] }
      placed.each do |page_id, element_ids|
        element_ids.each { |element_id| owners[element_id] << page_names.fetch(page_id, page_id) }
      end
      detail = duplicate_refs.map do |id, count|
        %(duplicate id "#{id}" (used #{count}x across #{owners[id].join(', ')}))
      end.join(', ')
      errors << "layout must place each element exactly once: #{detail}"
    end
    missing = ids - refs
    unknown = refs - ids
    errors << "layout does not place elements: #{missing.join(', ')}" if missing.any?
    errors << "layout references unknown elements: #{unknown.join(', ')}" if unknown.any?
    errors
  end
end
