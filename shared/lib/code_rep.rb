# shared/lib/code_rep.rb
# Shape adapter for the Sigma WORKBOOK code representation
# (POST /v2/workbooks, GET /v2/workbooks/{id}?includeContents=true,
# PUT /v2/workbooks/{id}/contents; dry-run = POST /v2/workbooks with dryRun: true).
#
# ENDPOINTS (OpenAPI 2.0.0+20261030, live-verified 2026-11-03): the /spec
# workbook and report endpoints are DEPRECATED. Their replacements carry the
# same document under `contents` instead of `document` (byte-identical on a
# live readback). Build paths and bodies with the endpoint helpers below rather
# than hand-writing them. On-disk artifacts keep the `document` wrapper that
# wrap() emits; create_body/update_body re-key it at the API boundary.
#
# Verified live 2026-08-03/04: this surface nests non-metadata fields under a top-level
# wrapper key and REJECTS the old flat body with HTTP 400 — including on dry-run.
# Sigma engineering confirmed 2026-08-03 that the DATA-MODEL code-rep surface is NOT
# changing, so this adapter is deliberately workbook-only and always writes the nested
# shape. Do NOT use it on /v2/dataModels/.../spec payloads — that API ignores `document`
# and will 400 on a missing top-level `schemaVersion`.
#
# Reads stay tolerant of the legacy flat shape because flat artifacts still exist on
# disk (committed workbook snapshots, fixtures) even though the API no longer returns them.
module Sigma
  module CodeRep
    # The non-metadata fields that live INSIDE `document`. Confirmed by live readback.
    # `elements`, `overlays`, and `panels` are workbook-document collections,
    # alongside page metadata and the required layout. `settings`
    # (theme/navigation) and `agents` belong here too. Omitting any of these
    # sweeps them onto the metadata envelope, where they are invalid and are
    # silently dropped on write.
    DOC_KEYS = %w[
      schemaVersion pages elements overlays panels kind layout settings agents
      automatedActions
    ].freeze

    # Envelope keys of the workbook/report responses that are never writable.
    # The /spec-era name (latestDocumentVersion) stays listed so old snapshots
    # strip the same way as live readbacks. folderId is writable, so it is kept.
    RESPONSE_ONLY_KEYS = %w[
      workbookId workbookUrlId reportId reportUrlId url path documentVersion
      latestVersion latestDocumentVersion ownerId createdBy updatedBy createdAt
      updatedAt isArchived tags taggedSourceUrlId warnings dryRun valid errors
    ].freeze
    CREATE_METADATA_KEYS = %w[name folderId description ownerId].freeze

    WORKBOOKS_PATH = '/v2/workbooks'
    REPORTS_PATH = '/v2/reports'

    # REMOVED from the API. The workbook theme is now `settings.theme.name` and
    # `settings.theme.overrides` (published OpenAPI: createWorkbookSpec — there
    # are zero occurrences of themeName/themeOverrides in it). The individual
    # override keys are unchanged (categoricalScheme, colorOverrides, hasCards,
    # borderRadius, elementBorder, titleFont, tableStyles, …) — only the
    # container path moved. document() folds the legacy pair forward so specs
    # and fixtures written before the move still produce a valid body.
    LEGACY_THEME_KEYS = %w[themeName themeOverrides].freeze
    LEGACY_HORIZONTAL_ALIGN = {
      'start' => 'left', 'middle' => 'center', 'end' => 'right'
    }.freeze
    LEGACY_VERTICAL_ALIGN = {
      'start' => 'top', 'middle' => 'center', 'end' => 'bottom'
    }.freeze

    class << self
      # Read path: accepts the live `contents` shape, the /spec-era `document`
      # shape, OR a legacy flat artifact.
      def document(response)
        return {} unless response.is_a?(Hash)
        inner = response['contents'].is_a?(Hash) ? response['contents'] : response['document']
        doc = inner.is_a?(Hash) ? inner : response.select { |k, _| DOC_KEYS.include?(k) }
        fold_legacy_theme(doc, response)
      end

      def metadata(response)
        return {} unless response.is_a?(Hash)
        response.reject do |k, _|
          %w[document contents].include?(k) || DOC_KEYS.include?(k) || LEGACY_THEME_KEYS.include?(k)
        end
      end

      # ---- Endpoint helpers -------------------------------------------------
      # `type` is :workbook or :report. Paths are relative to SIGMA_BASE_URL.

      # POST target for create and for dry-run validation.
      def create_path(type = :workbook)
        collection_path(type)
      end

      # GET that returns the envelope plus `contents` and `documentVersion`.
      def read_path(id, type = :workbook, document_version: nil)
        path = "#{collection_path(type)}/#{id}?includeContents=true"
        document_version ? "#{path}&documentVersion=#{Integer(document_version)}" : path
      end

      # PUT target that replaces an existing document.
      def update_path(id, type = :workbook)
        "#{collection_path(type)}/#{id}/contents"
      end

      # Create (or dry-run) body. `spec` may be a bare document, a `document`-
      # or `contents`-wrapped artifact, or a flat legacy artifact; its name /
      # folderId / description / ownerId are used unless overridden in `extra`.
      # Workbook contents are flattened/canonicalized like wrap(); report
      # contents are a different representation and pass through untouched.
      def create_body(spec, extra: {}, dry_run: false, type: :workbook)
        meta = metadata(spec).select { |k, _| CREATE_METADATA_KEYS.include?(k) }
        body = meta.merge(extra.transform_keys(&:to_s)).merge('contents' => api_contents(spec, type))
        body['dryRun'] = true if dry_run
        body
      end

      # Update body. Pass the documentVersion you read to make the PUT fail
      # with code stale_document_settings instead of overwriting newer edits.
      def update_body(spec, document_version: nil, type: :workbook)
        body = { 'contents' => api_contents(spec, type) }
        body['documentVersion'] = document_version if document_version
        body
      end

      # Normalize a dry-run response to the /spec/verify-era shape callers
      # check: { 'valid' => bool, 'errors' => [{ 'summary' => ... }] }.
      # Success is HTTP 200 with no `valid` key; a schema failure is HTTP 400
      # with valid:false and errors; other 4xx carry only `message`.
      def dry_run_result(status, body)
        status = status.to_i
        body = body.is_a?(Hash) ? body : {}
        return { 'valid' => true, 'errors' => [], 'warnings' => Array(body['warnings']) } if status.between?(200, 299)

        errors = Array(body['errors'])
        errors = [{ 'summary' => body['message'] || "HTTP #{status}" }] if errors.empty?
        { 'valid' => false, 'errors' => errors, 'warnings' => Array(body['warnings']) }
      end

      # Strip non-writable envelope keys (live and /spec-era) from a readback.
      def strip_response_only(spec)
        return spec unless spec.is_a?(Hash)
        spec.reject { |k, _| RESPONSE_ONLY_KEYS.include?(k) }
      end

      # Emitter helper — set the workbook theme on a document hash in the CURRENT
      # shape. Builders should call this instead of assigning the removed
      # themeName/themeOverrides pair. Returns the same hash for chaining.
      def set_theme(doc, name: nil, overrides: nil)
        return doc unless name || (overrides.is_a?(Hash) && !overrides.empty?)
        settings = (doc['settings'] ||= {})
        theme    = (settings['theme'] ||= {})
        theme['name'] = name if name
        if overrides.is_a?(Hash) && !overrides.empty?
          theme['overrides'] = (theme['overrides'] || {}).merge(overrides)
        end
        doc
      end

      # Read the theme back out of either shape (nested settings.theme, or a
      # legacy flat themeName/themeOverrides artifact). Returns {name:, overrides:}.
      def theme(spec)
        d = document(spec)
        t = d.dig('settings', 'theme') || {}
        { 'name' => t['name'], 'overrides' => t['overrides'] || {} }
      end

      # Write path: every live workbook code-rep endpoint requires the wrapper
      # and flat document.elements. Flatten legacy page-nested artifacts and
      # canonicalize rejected legacy layout tags and element alignment enums at
      # this boundary so older converter output remains postable during
      # migration. Also remove drawer.position, which no longer exists.
      def wrap(document_hash, extra: {})
        extra.merge('document' => canonicalize_document(flatten_elements(document_hash)))
      end

      # Read compatibility for pre-2026-08-08 artifacts. LayoutElement and
      # GridContainer are rejected by the live workbook verify endpoint, so
      # they must never cross an emission boundary unchanged.
      def canonicalize_layout(layout_xml)
        layout_xml.to_s
                  .gsub(%r{<(/?)LayoutElement\b}, '<\1Element')
                  .gsub(%r{<(/?)GridContainer\b}, '<\1Container')
      end

      # WORKBOOK-ONLY shape helpers. Workbook elements are a flat document
      # collection; pages contain metadata only. Page membership is encoded by
      # the required layout's <Page> blocks. Keep these helpers in CodeRep so
      # callers cannot accidentally apply this shape to data-model specs, whose
      # pages[*].elements nesting is unchanged.
      def workbook_elements(spec)
        doc = document(spec)
        els = doc['elements']
        return els.select { |el| el.is_a?(Hash) } if els.is_a?(Array)

        # Transitional read compatibility for saved pre-release workbook
        # artifacts. Current API payloads must still emit flat elements (wrap
        # enforces that); this fallback only prevents readers from silently
        # dropping elements while old local readbacks are being replaced.
        Array(doc['pages']).flat_map do |page|
          page.is_a?(Hash) ? Array(page['elements']).select { |el| el.is_a?(Hash) } : []
        end
      end

      # { region_id => [element_id, ...] }, in layout order. Pages, panels, and
      # overlays each own a top-level layout block with the same node shapes.
      def workbook_page_element_ids(spec)
        doc = document(spec)
        doc['layout'].to_s
                     .scan(%r{<(Page|Panel|Overlay)\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</\1>}m)
                     .each_with_object({}) do |(_tag, region_id, body), out|
          # Restrict ownership to actual layout nodes. A generic elementId
          # scan can accidentally claim ids from unrelated nested attributes.
          # Legacy aliases remain readable, but all writes canonicalize them.
          out[region_id] = body.scan(
            %r{<(?:Element|Container|TabbedContainer|LayoutElement|GridContainer)\b[^>]*\belementId="([^"]*)"}
          ).flatten.uniq
        end
      end

      # { element_id => page metadata hash }. Layout is authoritative; pages
      # that appear only in layout still receive a minimal {id,name} descriptor.
      def workbook_page_by_element(spec)
        doc = document(spec)
        pages = doc['pages'].is_a?(Array) ? doc['pages'].select { |pg| pg.is_a?(Hash) } : []
        pages_by_id = pages.each_with_object({}) { |pg, out| out[pg['id']] = pg if pg['id'] }
        workbook_page_element_ids(doc).each_with_object({}) do |(page_id, element_ids), out|
          page = pages_by_id[page_id] || { 'id' => page_id, 'name' => page_id }
          element_ids.each { |element_id| out[element_id] ||= page }
        end
      end

      # [[element, page_metadata_or_nil], ...] for flat workbook elements.
      def workbook_elements_with_pages(spec)
        page_by_element = workbook_page_by_element(spec)
        workbook_elements(spec).map do |el|
          [el, page_by_element[el['id'] || el['elementId']]]
        end
      end

      private

      def api_contents(spec, type)
        collection_path(type) # validates type
        type.to_sym == :workbook ? canonicalize_document(flatten_elements(document(spec))) : document(spec)
      end

      def collection_path(type)
        case type.to_sym
        when :workbook then WORKBOOKS_PATH
        when :report then REPORTS_PATH
        else raise ArgumentError, "unknown code-rep type #{type.inspect} (want :workbook or :report)"
        end
      end

      def canonicalize_document(doc)
        return doc unless doc.is_a?(Hash)
        out = doc
        if doc['elements'].is_a?(Array)
          out = out.merge('elements' => doc['elements'].map { |el| canonicalize_element(el) })
        end
        if doc['overlays'].is_a?(Array)
          out = out.merge('overlays' => doc['overlays'].map { |overlay| canonicalize_overlay(overlay) })
        end
        out = out.merge('layout' => canonicalize_layout(doc['layout'])) if doc.key?('layout')
        out
      end

      def canonicalize_element(element)
        return element unless element.is_a?(Hash)
        # `visibleAsSource` belongs to data-model elements only. The workbook
        # API rejects it even on hidden data-page tables:
        #   elements[0].visibleAsSource: only supported on data-model documents
        # Keep accepting it in local/legacy documents because downstream
        # readers use it as a hidden-helper hint, but never emit it across a
        # workbook code-representation boundary.
        element = element.reject { |key, _| key == 'visibleAsSource' } if element.key?('visibleAsSource')
        case element['kind']
        when 'text'
          mapped = LEGACY_VERTICAL_ALIGN[element['verticalAlign']]
          mapped ? element.merge('verticalAlign' => mapped) : element
        when 'kpi-chart'
          layout = element['layout']
          return element unless layout.is_a?(Hash)
          canonical = layout.dup
          canonical['anchor'] = LEGACY_HORIZONTAL_ALIGN[layout['anchor']] if LEGACY_HORIZONTAL_ALIGN.key?(layout['anchor'])
          if LEGACY_VERTICAL_ALIGN.key?(layout['verticalAnchor'])
            canonical['verticalAnchor'] = LEGACY_VERTICAL_ALIGN[layout['verticalAnchor']]
          end
          canonical == layout ? element : element.merge('layout' => canonical)
        when 'tabbed-container'
          tab_bar = element['tabBar']
          return element unless tab_bar.is_a?(Hash)
          mapped = LEGACY_HORIZONTAL_ALIGN[tab_bar['alignment']]
          mapped ? element.merge('tabBar' => tab_bar.merge('alignment' => mapped)) : element
        when 'divider'
          legacy = element['align']
          return element unless %w[start middle end].include?(legacy)
          mapping = element['direction'] == 'vertical' ? LEGACY_HORIZONTAL_ALIGN : LEGACY_VERTICAL_ALIGN
          element.merge('align' => mapping.fetch(legacy))
        else
          element
        end
      end

      def canonicalize_overlay(overlay)
        return overlay unless overlay.is_a?(Hash)
        drawer = overlay['drawer']
        return overlay unless drawer.is_a?(Hash) && drawer.key?('position')
        overlay.merge('drawer' => drawer.reject { |key, _| key == 'position' })
      end

      # Emit only the current API shape. Elements are workbook-global in the
      # payload; layout XML retains their page placement. Existing flat
      # elements win ordering, while legacy page-nested elements are appended
      # once by id.
      def flatten_elements(doc)
        return doc unless doc.is_a?(Hash)
        pages = doc['pages']
        return doc unless pages.is_a?(Array)

        flattened_pages = []
        nested_elements = []
        pages.each do |page|
          page_copy = page.dup
          nested_elements.concat(Array(page_copy.delete('elements')))
          flattened_pages << page_copy
        end
        existing_elements = Array(doc['elements'])
        elements = []
        seen = {}
        (existing_elements + nested_elements).each do |element|
          key = element.is_a?(Hash) && element['id']
          next if key && seen[key]
          seen[key] = true if key
          elements << element
        end

        doc.merge('pages' => flattened_pages, 'elements' => elements)
      end

      # themeName/themeOverrides -> settings.theme.{name,overrides}. Non-mutating:
      # only builds a new hash when a legacy key is actually present, so the
      # common (already-correct) path returns the input untouched.
      def fold_legacy_theme(doc, source)
        name      = doc['themeName']      || source['themeName']
        overrides = doc['themeOverrides'] || source['themeOverrides']
        has_ov    = overrides.is_a?(Hash) && !overrides.empty?
        return doc unless name || has_ov || doc.key?('themeName') || doc.key?('themeOverrides')

        out      = doc.reject { |k, _| LEGACY_THEME_KEYS.include?(k) }
        settings = (out['settings'] || {}).dup
        theme    = (settings['theme'] || {}).dup
        theme['name'] ||= name if name
        theme['overrides'] = (theme['overrides'] || {}).merge(overrides) if has_ov
        return out if theme.empty?

        settings['theme'] = theme
        out['settings'] = settings
        out
      end
    end
  end
end
