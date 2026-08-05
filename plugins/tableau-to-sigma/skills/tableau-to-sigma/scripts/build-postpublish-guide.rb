#!/usr/bin/env ruby
# Build the post-publish interactivity guide (POSTPUBLISH_GUIDE.md) from a
# Tableau .twb.
#
# Sigma's workbook spec (the JSON we POST) has NO representation for Tableau's
# dashboard interactivity layer: filter/highlight/URL/navigation actions,
# parameter actions, set actions, dynamic zone visibility, drill hierarchies,
# custom tooltips, and show/hide container buttons. Today that wiring is either
# approximated by controls during conversion or silently lost. This script
# closes the "silently lost" half: it parses every interaction the source
# workbook carries and emits a USER-FACING handoff document with exact Sigma UI
# steps for the ones Sigma can express, the control that already replaces the
# ones the conversion translated, and an honest "no equivalent — closest
# pattern" for the rest. Truthfulness over completeness: every UI instruction
# below is either a verified step pattern or explicitly marked
# "verify in your Sigma version".
#
# FILENAME CONTRACT: the orchestrator writes the guide to
# <workdir>/POSTPUBLISH_GUIDE.md — assert-phase6-ran / the finalize gate check
# for that exact file when the gap scan detects any action, so do not rename it.
# The script always writes the file (a zero-action workbook gets a minimal
# "no interactive actions detected" guide) so the gate can never race a
# conditional emit.
#
# Usage:
#   ruby scripts/build-postpublish-guide.rb \
#     --twb  /tmp/<name>/workbook-content.twb \
#     --out  /tmp/<name>/POSTPUBLISH_GUIDE.md \
#     [--wb-ids   /tmp/<name>/wb-ids.json]        # name real Sigma elements/pages
#     [--json-out /tmp/<name>/postpublish-guide.json]
#     [--sigma-url https://app.sigmacomputing.com/.../workbook/...]
#
# What gets parsed (structures verified against a 10-workbook live migration:
# ecommerce-admin, dynamic-zoning-kpi, superstore-performance, supermart-sales):
#   <actions>/<action>            command tsc:tsl-filter → filter action
#                                 command tsc:brush      → highlight action
#                                 command tsc:url / http(s) <link> → URL action
#   <actions>/<nav-action>        go-to-sheet navigation
#   <actions>/<edit-parameter-action>  parameter action (source field → param)
#   <actions>/<edit-set-action>   set action
#   <object-graph> visibility nodes    dynamic zone visibility
#     (<single-value-field-node> → <edge> → <dashboard-zone-visibility-node>,
#      dashboard resolved via its <simple-id uuid>, zone via zone-id)
#   <drill-paths>/<drill-path>    drill hierarchies
#   <customized-tooltip>          custom tooltips w/ field refs or viz-in-tooltip
#                                 (<Sheet name=…> inside the tooltip text)
#   <zone>/<button>               <toggle-action> show/hide container buttons,
#                                 <export-button-action> export buttons, and
#                                 <zone type-v2='button'> zones
#
# JSON sidecar (--json-out): [{kind, caption, source, targets, fields,
# sigma_status, ui_steps, notes}] for downstream tooling / the conversion
# report, which must LINK the guide (refs/postpublish-interactivity.md).

require 'json'
require 'optparse'
require 'uri'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'

module PostpublishGuide
  module_function

  # Machine-readable sigma_status values ↔ the user-facing labels.
  STATUS_UI    = 'ui-configurable'.freeze
  STATUS_BUILT = 'control-equivalent-built'.freeze
  STATUS_NONE  = 'no-equivalent'.freeze
  STATUS_LABEL = {
    STATUS_UI    => 'UI-configurable',
    STATUS_BUILT => 'control-based equivalent already built',
    STATUS_NONE  => 'no equivalent'
  }.freeze

  # ---- Verified Sigma UI step patterns --------------------------------------
  # These are the ONLY UI paths the guide states as fact. Anything else must be
  # tagged "(verify in your Sigma version)". Do not paraphrase them into new
  # claims.
  STEPS_USE_AS_FILTER =
    "Open the workbook in edit mode → select the source chart → element menu " \
    "(⋮ or right-click) → 'Use as filter' → in the dialog pick the target " \
    "elements and the matching columns → Save.".freeze
  STEPS_BUTTON_NAV =
    "Add a Button element (UI: Add element → UI → Button) → set 'Navigate to " \
    "page' → pick the target page; or a text element with the page link.".freeze
  STEPS_URL_COLUMN =
    "Chart editor → add a column with the URL formula (template shown) → " \
    "table/chart cell links, or add a text element with a templated link.".freeze
  STEPS_DRILL =
    "Chart editor → the dimension's column menu → 'Drill down' / add drill " \
    "anywhere; configure the drill order to mirror the Tableau hierarchy.".freeze
  STEPS_TOOLTIP =
    "Chart editor → Tooltip panel → add the fields listed.".freeze

  # ---- Column caption resolver ----------------------------------------------
  # Same registration scheme as parse-twb-layout.rb's COL_BY_GUID: GUID-shaped
  # and Calculation_<n> column names resolve via their head token (only useful
  # when a caption exists); friendly/group/copy names register under the FULL
  # bracket body, falling the caption back to the body itself (plain warehouse
  # columns carry no caption attribute — their name IS the display name).
  def build_column_lookup(xml)
    lut = {}
    xml.elements.each('//column') do |c|
      raw = c.attributes['name'].to_s
      cap = c.attributes['caption']
      next if raw.empty?
      body = raw.sub(/\A\[/, '').sub(/\]\z/, '')
      if body =~ /\A([0-9a-f]{8}-[0-9a-f\-]{20,}|Calculation_\d+)/i
        head = body.split(/\s/, 2).first
        lut[head] ||= cap if cap && !cap.empty?
      else
        lut[body] ||= (cap && !cap.empty? ? cap : body)
      end
    end
    lut
  end

  # Strip Tableau's "(copy)_<digits>" / "(copy)" decorations off a field name so
  # the guide shows the label the user knows from Tableau.
  def tidy_name(s)
    s.to_s.sub(/\s*\(copy\)(?:_\d+)?\z/i, '').strip
  end

  # Resolve a Tableau field reference of any of the shapes
  #   [DS].[none:Name:nk]   [DS].[usr:Calculation_123:qk]   [DS].[Name]   [Name]
  # to a human-readable caption. Unresolvable Calculation_<n> ids degrade to
  # "(calculated field)" rather than leaking internal ids into a user document.
  def field_caption(ref, lut)
    return nil if ref.nil? || ref.to_s.empty?
    inner = ref[/\.\[([^\[\]]+)\]\s*\z/, 1] || ref[/\A\[([^\[\]]+)\]\z/, 1] || ref.to_s
    # Strip the derivation/qualifier wrapper: none:X:nk, usr:X:qk, and the
    # 4-segment usr:X:nk:1 shape (instance-numbered refs).
    inner = Regexp.last_match(1) if inner =~ /\A[a-z]+:(.+?):[a-z]+(?::\d+)?\z/i
    inner = inner.sub(/\A:/, '') # ":Measure Names"-style internal pills
    cap = lut[inner]
    if cap.nil? && inner =~ /\A(Calculation_\d+|[0-9a-f]{8}-[0-9a-f\-]{20,})/i
      cap = lut[inner.split(/\s/, 2).first]
    end
    resolved = tidy_name(cap || inner)
    return '(calculated field)' if resolved =~ /\ACalculation_\d+\z/i
    resolved
  end

  # ---- Dashboard / zone index -----------------------------------------------
  # One entry per dashboard: uuid (its <simple-id>), the worksheet names placed
  # on it, and a zone-id → description map (worksheet name, text excerpt, or
  # container) used to resolve zone-visibility targets and toggle-button
  # targets.
  def build_dashboard_index(xml)
    dashboards = []
    xml.elements.each('//dashboards/dashboard') do |d|
      name = d.attributes['name'].to_s
      next if name.empty?
      entry = { name: name, uuid: nil, worksheets: [], zones_by_id: {} }
      sid = d.elements['.//simple-id']
      entry[:uuid] = sid.attributes['uuid'].to_s if sid
      d.elements.each('.//zone') do |z|
        zid   = z.attributes['id'].to_s
        zname = z.attributes['name']
        tv2   = z.attributes['type-v2'].to_s
        desc =
          if zname && !zname.to_s.empty?
            "sheet '#{zname}'"
          elsif tv2 == 'text' || tv2 == 'title'
            runs = []
            z.elements.each('.//formatted-text/run') { |r| runs << r.text.to_s }
            t = runs.join(' ').gsub(/\s+/, ' ').strip
            t.empty? ? 'text zone' : "text zone (\"#{t[0, 40]}#{t.length > 40 ? '…' : ''}\")"
          else
            # Containers/other chrome: name the sheets nested inside so two
            # toggled/hidden containers are distinguishable in the guide.
            kids = []
            z.elements.each('.//zone') do |c|
              kn = c.attributes['name']
              kids << kn.to_s if kn && !kn.to_s.empty?
            end
            kids.uniq!
            base = tv2.empty? ? 'container' : "#{tv2} container"
            kids.empty? ? "#{base} (zone #{zid})" : "#{base} holding #{cap_list(kids, 3)}"
          end
        entry[:zones_by_id][zid] = { desc: desc, worksheet: zname && zname.to_s } unless zid.empty?
        entry[:worksheets] << zname.to_s if zname && !zname.to_s.empty?
      end
      entry[:worksheets].uniq!
      dashboards << entry
    end
    dashboards
  end

  # ---- <source> element → human description ---------------------------------
  # Sources come in two shapes: a single worksheet, or "every sheet on
  # dashboard D except the <exclude-sheet> list".
  def parse_source(node)
    src = node && node.elements['source']
    return { 'description' => '(unknown source)' } unless src
    dash = src.attributes['dashboard']
    ws   = src.attributes['worksheet']
    excludes = []
    src.elements.each('exclude-sheet') { |e| excludes << e.attributes['name'].to_s }
    out = {}
    out['dashboard']  = dash.to_s if dash && !dash.to_s.empty?
    out['worksheets'] = [ws.to_s] if ws && !ws.to_s.empty?
    out['excludes']   = excludes unless excludes.empty?
    out['description'] =
      if out['worksheets']
        d = out['dashboard'] ? " (on dashboard '#{out['dashboard']}')" : ''
        "sheet '#{out['worksheets'].first}'#{d}"
      elsif out['dashboard']
        ex = excludes.empty? ? '' : ", except: #{cap_list(excludes, 6)}"
        "any sheet on dashboard '#{out['dashboard']}'#{ex}"
      else
        '(workbook-wide)'
      end
    out
  end

  def cap_list(list, n)
    list = list.compact.map(&:to_s)
    shown = list.first(n)
    extra = list.length - shown.length
    shown.join(', ') + (extra > 0 ? " (+#{extra} more)" : '')
  end

  def activation_of(node)
    act = node && node.elements['activation']
    t = act && act.attributes['type'].to_s
    case t
    when 'on-select' then 'on select'
    when 'on-hover'  then 'on hover'
    when 'on-menu', 'on-menu-item' then 'from the tooltip menu'
    else t.to_s.empty? ? nil : t
    end
  end

  # Field-name pairs out of a tsl: <link expression> — the mapping is
  # `…[TargetField]~s0=<[DS].[SourceField]~na>` per field, URL-escaped. We only
  # need the human field names, deduped.
  def link_fields(link, lut)
    expr = link && link.attributes['expression'].to_s
    return [] if expr.nil? || expr.empty?
    decoded = begin
      URI.decode_www_form_component(expr)
    rescue StandardError
      expr
    end
    fields = []
    decoded.scan(/\[([^\[\]]+)\]\.\[([^\[\]]+)\]/) do |_ds, f|
      fields << field_caption("[x].[#{f}]", lut)
    end
    fields.uniq
  end

  # ---- Rewrite a Tableau URL-action template as a Sigma formula --------------
  # Tableau placeholders are <Field> or <[DS].[Field]>; Sigma wants a string
  # concat with column refs: "https://…?" & [Field] & "…"
  def sigma_url_formula(template, lut)
    return nil if template.nil? || template.empty?
    segs = template.split(/(<[^<>]+>)/).reject(&:empty?)
    parts = segs.map do |s|
      if s =~ /\A<(.+)>\z/m
        "[#{field_caption(Regexp.last_match(1), lut)}]"
      else
        '"' + s.gsub('"', '\"') + '"'
      end
    end
    parts.join(' & ')
  end

  # ---- wb-ids.json mapping ---------------------------------------------------
  # {workbookId, pages:[{id,name,elements:[{id,kind,name}]}]} — match Tableau
  # names to built Sigma pages/elements so the guide names real elements.
  def load_wb_ids(path)
    return nil unless path && File.exist?(path)
    data = JSON.parse(File.read(path))
    pages = data['pages'] || []
    elements = []
    pages.each do |pg|
      (pg['elements'] || []).each do |el|
        elements << el.merge('page' => pg['name'])
      end
    end
    { 'pages' => pages, 'elements' => elements }
  rescue JSON::ParserError => e
    warn "WARN: --wb-ids unparseable (#{e.message}) — guide will use Tableau names only"
    nil
  end

  def norm_name(s)
    s.to_s.downcase.gsub(/\s+/, ' ').strip
  end

  # Exact normalized match first, then a unique substring match (either
  # direction, ≥4 chars to avoid junk hits). Returns nil when ambiguous.
  def match_named(name, candidates)
    n = norm_name(name)
    return nil if n.empty?
    exact = candidates.select { |c| norm_name(c['name']) == n }
    return exact.first if exact.length == 1
    return nil if n.length < 4
    subs = candidates.select do |c|
      cn = norm_name(c['name'])
      cn.length >= 4 && (cn.include?(n) || n.include?(cn))
    end
    subs.length == 1 ? subs.first : nil
  end

  def sigma_page_for(name, wbids)
    return nil unless wbids
    match_named(name, wbids['pages'])
  end

  def sigma_element_for(name, wbids, kinds = nil)
    return nil unless wbids
    pool = wbids['elements'].reject { |e| e['name'].to_s.strip.empty? }
    pool = pool.select { |e| kinds.include?(e['kind']) } if kinds
    match_named(name, pool)
  end

  # "cus_list" → "cus_list (Sigma: 'Customer List' on page 'Customers')" when a
  # wb-ids match exists; the bare Tableau name otherwise.
  def annotate(name, wbids, kinds = nil)
    el = sigma_element_for(name, wbids, kinds)
    return name.to_s unless el
    "#{name} (Sigma: '#{el['name']}' on page '#{el['page']}')"
  end

  # ==== Interaction extraction ===============================================
  # Every extractor returns entries shaped:
  #   { 'kind' =>, 'caption' =>, 'source' => {…}, 'targets' => [...],
  #     'fields' => [...], 'sigma_status' =>, 'ui_steps' =>, 'notes' => [...] }

  def extract_action_blocks(xml, lut, dashboards)
    out = []
    seen = {}
    xml.elements.each('//actions/action') do |a|
      name = a.attributes['name'].to_s
      next if !name.empty? && seen[name]
      seen[name] = true
      caption = a.attributes['caption'].to_s
      cmd  = a.elements['command']
      link = a.elements['link']
      cmd_kind = cmd && cmd.attributes['command'].to_s
      params = {}
      if cmd
        cmd.elements.each('param') { |p| params[p.attributes['name'].to_s] = p.attributes['value'].to_s }
      end
      source = parse_source(a)
      trigger = activation_of(a)
      link_expr = link && link.attributes['expression'].to_s

      kind =
        case cmd_kind
        when 'tsc:tsl-filter', 'tsc:filter' then 'filter-action'
        when 'tsc:brush'                    then 'highlight-action'
        when 'tsc:url'                      then 'url-action'
        else
          link_expr.to_s =~ %r{\Ahttps?://}i ? 'url-action' : nil
        end
      next unless kind

      entry = { 'kind' => kind, 'caption' => caption, 'source' => source,
                'trigger' => trigger, 'notes' => [] }

      case kind
      when 'filter-action'
        fields = link_fields(link, lut)
        fields = ['(all shared fields)'] if fields.empty? && params['special-fields'] == 'all'
        entry['fields']  = fields
        entry['targets'] = expand_target(params['target'], params['exclude'], dashboards)
        entry['sigma_status'] = STATUS_UI
        entry['ui_steps'] = STEPS_USE_AS_FILTER
        entry['notes'] << "Applies element-to-element filters; verify the join columns match the Tableau action's field mapping."
      when 'highlight-action'
        fields = (params['field-captions'] || '').split(',').map { |f| tidy_name(f) }.reject(&:empty?)
        entry['fields']  = fields
        entry['targets'] = expand_target(params['target'], params['exclude'], dashboards)
        entry['sigma_status'] = STATUS_NONE
        entry['ui_steps'] =
          "No Sigma equivalent (no cross-element highlight). Closest: the same " \
          "source→target wiring as a filter — #{STEPS_USE_AS_FILTER} — or a shared " \
          'list control on the highlight field.'
        src_ws = (source['worksheets'] || []).first
        if fields == ['Dummy'] || (src_ws && params['target'] == src_ws)
          entry['notes'] << 'Self-highlight on a dummy field — the Tableau button-flash idiom. Cosmetic only; usually safe to drop in Sigma.'
        end
      when 'url-action'
        entry['fields']  = link_expr.to_s.scan(/<([^<>]+)>/).flatten.map { |r| field_caption(r, lut) }.uniq
        entry['targets'] = [{ 'name' => link_expr.to_s }]
        entry['url_template']  = link_expr
        entry['sigma_formula'] = sigma_url_formula(link_expr, lut)
        entry['sigma_status']  = STATUS_UI
        entry['ui_steps'] = STEPS_URL_COLUMN
      end
      out << entry
    end
    out
  end

  # A filter/highlight `target` param names a dashboard (usually) or a single
  # sheet; `exclude` lists target-side sheets the action skips. Expand to the
  # concrete sheet list when we know the dashboard.
  def expand_target(target, exclude, dashboards)
    return [] if target.nil? || target.empty?
    excludes = (exclude || '').split(',').map(&:strip).reject(&:empty?)
    dash = dashboards.find { |d| d[:name] == target }
    if dash
      sheets = dash[:worksheets] - excludes
      [{ 'name' => target, 'dashboard' => true, 'sheets' => sheets }]
    else
      [{ 'name' => target }]
    end
  end

  def extract_nav_actions(xml, dashboards)
    out = []
    seen = {}
    xml.elements.each('//actions/nav-action') do |a|
      name = a.attributes['name'].to_s
      next if !name.empty? && seen[name]
      seen[name] = true
      target_sheet = nil
      a.elements.each('params/param') do |p|
        target_sheet = p.attributes['value'].to_s if p.attributes['name'].to_s == 'sheet'
      end
      is_dash = dashboards.any? { |d| d[:name] == target_sheet }
      out << {
        'kind'    => 'nav-action',
        'caption' => a.attributes['caption'].to_s,
        'source'  => parse_source(a),
        'trigger' => activation_of(a),
        'targets' => [{ 'name' => target_sheet, 'dashboard' => is_dash }],
        'fields'  => [],
        'sigma_status' => STATUS_UI,
        'ui_steps' => STEPS_BUTTON_NAV,
        'notes'   => ['Sigma buttons support page navigation in the UI; this wiring is not spec-persistable, so it must be added after publish.']
      }
    end
    out
  end

  def extract_parameter_actions(xml, lut)
    out = []
    seen = {}
    xml.elements.each('//actions/edit-parameter-action') do |a|
      name = a.attributes['name'].to_s
      next if !name.empty? && seen[name]
      seen[name] = true
      src_field = tgt_param = nil
      a.elements.each('params/param') do |p|
        case p.attributes['name'].to_s
        when 'source-field'      then src_field = p.attributes['value'].to_s
        when 'target-parameter'  then tgt_param = p.attributes['value'].to_s
        end
      end
      out << {
        'kind'      => 'parameter-action',
        'caption'   => a.attributes['caption'].to_s,
        'source'    => parse_source(a),
        'trigger'   => activation_of(a),
        'fields'    => [field_caption(src_field, lut)].compact,
        'targets'   => [{ 'name' => field_caption(tgt_param, lut), 'parameter' => true }],
        'sigma_status' => STATUS_BUILT,
        'ui_steps'  => '',   # filled in by the wb-ids pass / renderer
        'notes'     => []
      }
    end
    out
  end

  def extract_set_actions(xml, lut)
    out = []
    seen = {}
    xml.elements.each('//actions/edit-set-action') do |a|
      name = a.attributes['name'].to_s
      next if !name.empty? && seen[name]
      seen[name] = true
      tgt_set = nil
      a.elements.each('params/param') do |p|
        tgt_set = p.attributes['value'].to_s if p.attributes['name'].to_s == 'target-set'
      end
      out << {
        'kind'      => 'set-action',
        'caption'   => a.attributes['caption'].to_s,
        'source'    => parse_source(a),
        'trigger'   => activation_of(a),
        'fields'    => [],
        'targets'   => [{ 'name' => field_caption(tgt_set, lut), 'set' => true }],
        'sigma_status' => STATUS_NONE,
        'ui_steps'  =>
          'No Sigma sets. Closest pattern: a list control on the same dimension ' \
          'plus a boolean helper column (If(Contains(...))) that downstream calcs reference in place of the set.',
        'notes'     => []
      }
    end
    out
  end

  # Dynamic zone visibility: <single-value-field-node fieldname=… value-output-
  # guid=X> --<edge from=X to=Y>--> <dashboard-zone-visibility-node
  # visibility-input-guid=Y zone-id=… dashboard-identifier={uuid}>. The uuid
  # matches the dashboard's <simple-id>. (Structure verified against the
  # dynamic-zoning-kpi live-migration workbook.)
  def extract_zone_visibility(xml, lut, dashboards)
    field_by_output = {}
    xml.elements.each('//single-value-field-node') do |n|
      field_by_output[n.attributes['value-output-guid'].to_s] = n.attributes['fieldname'].to_s
    end
    from_by_to = {}
    xml.elements.each('//edge') do |e|
      from_by_to[e.attributes['to'].to_s] = e.attributes['from'].to_s
    end
    out = []
    xml.elements.each('//dashboard-zone-visibility-node') do |n|
      uuid = n.attributes['dashboard-identifier'].to_s
      dash = dashboards.find { |d| d[:uuid] == uuid }
      zid  = n.attributes['zone-id'].to_s
      zone = dash && dash[:zones_by_id][zid]
      raw_field = field_by_output[from_by_to[n.attributes['visibility-input-guid'].to_s]]
      field = raw_field ? field_caption(raw_field, lut) : nil
      out << {
        'kind'    => 'zone-visibility',
        'caption' => "#{zone ? zone[:desc] : "zone #{zid}"}#{dash ? " on '#{dash[:name]}'" : ''}",
        'source'  => { 'dashboard' => dash && dash[:name],
                       'description' => field ? "driven by field/parameter '#{field}'" : 'driving field unresolved' },
        'trigger' => nil,
        'fields'  => [field].compact,
        'targets' => [{ 'name' => zone ? zone[:desc] : "zone #{zid}", 'zone_id' => zid }],
        'sigma_status' => STATUS_NONE,
        'ui_steps' =>
          'No direct equivalent today; shipped pattern: the conversion creates a page per ' \
          'visibility state (when applicable) — the control that replaced the driving ' \
          'parameter selects the data, and page tabs switch the layout state.',
        'notes'   => []
      }
    end
    out
  end

  def extract_drill_paths(xml, lut)
    out = []
    seen = {}
    xml.elements.each('//drill-paths/drill-path') do |dp|
      name = dp.attributes['name'].to_s
      levels = []
      dp.elements.each('field') { |f| levels << field_caption(f.text.to_s, lut) }
      key = [name, levels].inspect
      next if seen[key]
      seen[key] = true
      out << {
        'kind'    => 'drill-hierarchy',
        'caption' => name,
        'source'  => { 'description' => 'datasource hierarchy' },
        'trigger' => nil,
        'fields'  => levels,
        'targets' => [],
        'sigma_status' => STATUS_UI,
        'ui_steps' => "#{STEPS_DRILL} Drill order: #{levels.join(' → ')}.",
        'notes'   => []
      }
    end
    out
  end

  # Custom tooltips — best-effort: only worksheets whose <customized-tooltip>
  # carries dynamic field refs (`<[DS].[field]>`) or an embedded viz
  # (`<Sheet name=…>`), and only worksheets actually placed on a dashboard
  # (when the workbook has dashboards) so the guide isn't flooded by scratch
  # sheets.
  def extract_tooltips(xml, lut, dashboards)
    on_dash = dashboards.flat_map { |d| d[:worksheets] }
    out = []
    xml.elements.each('//worksheet') do |ws|
      name = ws.attributes['name'].to_s
      next if name.empty?
      next if !on_dash.empty? && !on_dash.include?(name)
      tip = ws.elements['.//customized-tooltip']
      next unless tip
      text = String.new
      tip.elements.each('.//run') { |r| text << r.text.to_s << "\n" }
      has_viz = !!(text =~ /<Sheet\s+name=/i)
      fields = text.scan(/<\[([^\[\]]+)\]\.\[([^\[\]]+)\]>/)
                   .map { |_ds, f| field_caption("[x].[#{f}]", lut) }
                   .reject { |f| f =~ /\A(Measure Names|Measure Values|Multiple Values)\z/i }
                   .uniq
      next unless has_viz || !fields.empty?
      entry = {
        'kind'    => 'custom-tooltip',
        'caption' => name,
        'source'  => { 'worksheets' => [name], 'description' => "sheet '#{name}'" },
        'trigger' => nil,
        'fields'  => fields,
        'targets' => [],
        'viz_in_tooltip' => has_viz,
        'notes'   => []
      }
      if has_viz
        entry['sigma_status'] = STATUS_NONE
        entry['ui_steps'] =
          'Embedded viz-in-tooltip has no Sigma equivalent. Closest: add the fields to the ' \
          "tooltip (#{STEPS_TOOLTIP.sub(/\.$/, '')}) and give the embedded viz its own chart, " \
          "wired via 'Use as filter' from this element."
      else
        entry['sigma_status'] = STATUS_UI
        entry['ui_steps'] = "#{STEPS_TOOLTIP.sub(/ listed\.$/, '')}: #{fields.join(', ')}."
      end
      out << entry
    end
    out
  end

  # <window class='dashboard' name='X'><simple-id uuid='{…}'/> — navigation
  # buttons (`action='tabdoc:goto-sheet window-id="{…}"'`) point at windows.
  def build_window_index(xml)
    idx = {}
    xml.elements.each('//windows/window') do |w|
      name = w.attributes['name'].to_s
      sid  = w.elements['.//simple-id']
      idx[sid.attributes['uuid'].to_s] = name if sid && !name.empty?
    end
    idx
  end

  # Show/hide container toggles + export buttons + goto-sheet navigation
  # buttons. The <toggle-action> text carries `zone-id="<button>"
  # zone-ids=[<targets>]`; both ids resolve inside the dashboard whose zone
  # tree contains the button.
  def extract_buttons(xml, dashboards)
    windows = build_window_index(xml)
    out = []
    # Device/phone layouts clone the desktop zone tree, so the same button can
    # appear 2-3× per dashboard; dedupe on what the user would perceive as one
    # button (dashboard + caption + resolved targets).
    seen = {}
    push = lambda do |entry|
      key = [entry['source']['dashboard'], entry['kind'], entry['caption'],
             (entry['targets'] || []).map { |t| t['name'] }].inspect
      out << entry unless seen[key]
      seen[key] = true
    end
    xml.elements.each('//dashboards/dashboard') do |d|
      dname = d.attributes['name'].to_s
      dash  = dashboards.find { |x| x[:name] == dname }
      d.elements.each('.//zone') do |z|
        btn = z.elements['button']
        if btn.nil?
          next unless z.attributes['type-v2'].to_s == 'button'
          # bare button zone with no <button> payload — surface it generically
          push.call(
            'kind' => 'nav-button', 'caption' => "button zone #{z.attributes['id']}",
            'source' => { 'dashboard' => dname, 'description' => "dashboard '#{dname}'" },
            'trigger' => nil, 'fields' => [], 'targets' => [],
            'sigma_status' => STATUS_UI, 'ui_steps' => STEPS_BUTTON_NAV, 'notes' => []
          )
          next
        end
        caption = nil
        vs = btn.elements['button-visual-state']
        if vs
          c = vs.elements['caption']
          t = vs.elements['tooltip-text']
          i = vs.elements['image-path']
          caption = (c && c.text) || (t && t.text) || (i && File.basename(i.text.to_s))
        end
        caption = caption.to_s.strip
        caption = "button (zone #{z.attributes['id']})" if caption.empty?

        toggle = btn.elements['toggle-action']
        export = btn.elements['export-button-action']
        if toggle
          ttext = toggle.text.to_s
          target_ids = ttext[/zone-ids=\[([0-9,\s]*)\]/, 1].to_s.split(',').map(&:strip).reject(&:empty?)
          targets = target_ids.map do |tid|
            zi = dash && dash[:zones_by_id][tid]
            { 'name' => zi ? zi[:desc] : "zone #{tid}", 'zone_id' => tid }
          end
          push.call(
            'kind'    => 'show-hide-button',
            'caption' => caption,
            'source'  => { 'dashboard' => dname, 'description' => "button '#{caption}' on dashboard '#{dname}'" },
            'trigger' => 'on click',
            'fields'  => [],
            'targets' => targets,
            'sigma_status' => STATUS_NONE,
            'ui_steps' =>
              'No direct equivalent today (Sigma has no show/hide container toggle in the ' \
              "workbook spec). Closest pattern: move the toggled content to its own page and add a " \
              "Button navigation to it (#{STEPS_BUTTON_NAV})",
            'notes'   => []
          )
        elsif export
          fmt = export.text.to_s[/dashboard-button-export-type=["&quot;]*([a-z-]+)/i, 1]
          push.call(
            'kind'    => 'export-button',
            'caption' => caption,
            'source'  => { 'dashboard' => dname, 'description' => "button '#{caption}' on dashboard '#{dname}'" },
            'trigger' => 'on click',
            'fields'  => [],
            'targets' => [{ 'name' => "export as #{fmt || 'file'}" }],
            'sigma_status' => STATUS_UI,
            'ui_steps' =>
              'No per-dashboard export button element is needed: Sigma exposes export/download ' \
              'natively from the workbook and element menus (verify in your Sigma version).',
            'notes'   => []
          )
        else
          # `action='tabdoc:goto-sheet window-id="{…}"'` → dashboard navigation.
          target_uuid = btn.attributes['action'].to_s[/goto-sheet window-id="\{([0-9A-Fa-f-]+)\}"/, 1]
          target_name = target_uuid && windows["{#{target_uuid.upcase}}"]
          target_name ||= target_uuid && windows["{#{target_uuid}}"]
          entry = {
            'kind'    => 'nav-button',
            'caption' => caption,
            'source'  => { 'dashboard' => dname, 'description' => "button '#{caption}' on dashboard '#{dname}'" },
            'trigger' => 'on click',
            'fields'  => [],
            'targets' => target_name ? [{ 'name' => target_name, 'dashboard' => true }] : [],
            'sigma_status' => STATUS_UI,
            'ui_steps' => STEPS_BUTTON_NAV,
            'notes'   => []
          }
          if target_name && target_name == dname
            entry['notes'] << "Self-navigation (Tableau 'refresh view' idiom) — not needed in Sigma; safe to drop."
          end
          push.call(entry)
        end
      end
    end
    out
  end

  # ---- wb-ids enrichment ----------------------------------------------------
  # Attach real Sigma element/page names wherever a Tableau name matches, and
  # resolve which built control replaces each parameter action.
  def enrich_with_wb_ids(entries, wbids)
    entries.each do |e|
      src = e['source'] || {}
      (src['worksheets'] || []).each_with_index do |wsn, i|
        el = sigma_element_for(wsn, wbids)
        src['worksheets'][i] = "#{wsn} (Sigma: '#{el['name']}' on page '#{el['page']}')" if el
      end
      if src['dashboard'] && wbids
        pg = sigma_page_for(src['dashboard'], wbids)
        src['sigma_page'] = pg['name'] if pg
      end
      (e['targets'] || []).each do |t|
        next unless wbids
        if t['dashboard']
          pg = sigma_page_for(t['name'], wbids)
          t['sigma_page'] = pg['name'] if pg
          if t['sheets']
            t['sheets'] = t['sheets'].map do |s|
              el = sigma_element_for(s, wbids)
              el ? "#{s} (Sigma: '#{el['name']}')" : s
            end
          end
        elsif t['parameter']
          ctl = sigma_element_for(t['name'], wbids, %w[control])
          t['sigma_control'] = ctl['name'] if ctl
        else
          el = sigma_element_for(t['name'], wbids)
          t['sigma_element'] = el['name'] if el
        end
      end
      # Parameter actions: name the control that replaces the click wiring.
      if e['kind'] == 'parameter-action'
        ctl = (e['targets'] || []).map { |t| t['sigma_control'] }.compact.first
        pname = (e['targets'] || []).map { |t| t['name'] }.compact.first || 'the parameter'
        e['ui_steps'] =
          if ctl
            "Already replicated: the Sigma control '#{ctl}' replaces parameter '#{pname}' — " \
            'clicking the control sets the same value. The click-driven flavor ' \
            '(chart-click-sets-control) is on the Sigma UI roadmap; control-click is the equivalent today.'
          else
            # No exact-name control match; when wb-ids resolves the source
            # dashboard to a page, name that page's controls as candidates so
            # the user isn't left grepping.
            hint = ''
            if wbids && src['sigma_page']
              cands = wbids['elements'].select { |el| el['kind'] == 'control' && el['page'] == src['sigma_page'] }
                                       .map { |el| el['name'].to_s.strip }.reject(&:empty?)
              hint = " (page '#{src['sigma_page']}' has controls: #{cap_list(cands, 5)})" unless cands.empty?
            end
            "The conversion normally replicates this parameter as a control — check the published " \
            "workbook for a control replacing '#{pname}'#{hint}. The click-driven flavor " \
            '(chart-click-sets-control) is on the Sigma UI roadmap; control-click is the equivalent today.'
          end
      end
    end
    entries
  end

  # ==== Rendering ============================================================

  SECTION_ORDER = %w[
    filter-action highlight-action url-action nav-action parameter-action
    set-action zone-visibility drill-hierarchy custom-tooltip
    show-hide-button nav-button export-button integer-dim-decode
  ].freeze

  SECTION_TITLE = {
    'filter-action'    => 'Cross-element filter actions',
    'highlight-action' => 'Highlight actions',
    'url-action'       => 'URL actions',
    'nav-action'       => 'Navigation (go-to-sheet) actions',
    'parameter-action' => 'Parameter actions',
    'set-action'       => 'Set actions',
    'zone-visibility'  => 'Dynamic zone visibility',
    'drill-hierarchy'  => 'Drill hierarchies',
    'custom-tooltip'   => 'Custom tooltips',
    'show-hide-button' => 'Show/hide container buttons',
    'nav-button'       => 'Navigation buttons',
    'export-button'    => 'Export buttons',
    'integer-dim-decode' => 'Integer-coded dimension filters needing a manual Text() decode'
  }.freeze

  SECTION_SINGULAR = {
    'filter-action'    => 'Filter action',
    'highlight-action' => 'Highlight action',
    'url-action'       => 'URL action',
    'nav-action'       => 'Navigation action',
    'parameter-action' => 'Parameter action',
    'set-action'       => 'Set action',
    'zone-visibility'  => 'Dynamic zone visibility',
    'drill-hierarchy'  => 'Drill hierarchy',
    'custom-tooltip'   => 'Custom tooltip',
    'show-hide-button' => 'Show/hide button',
    'nav-button'       => 'Navigation button',
    'export-button'    => 'Export button',
    'integer-dim-decode' => 'Integer-coded dimension filter'
  }.freeze

  SECTION_INTRO = {
    'filter-action'    => 'Clicking marks on the source sheet filtered the target sheets in Tableau. Sigma expresses this as element-to-element filters.',
    'highlight-action' => 'Selecting marks visually highlighted related marks on other sheets. Sigma has no cross-element highlight.',
    'url-action'       => 'Clicking a mark opened a templated URL.',
    'nav-action'       => 'Clicking the source sheet jumped to another dashboard/sheet. In the converted workbook each Tableau dashboard is a Sigma page.',
    'parameter-action' => 'Clicking marks pushed a value into a Tableau parameter, which calcs referenced. The conversion replaces parameters with Sigma controls.',
    'set-action'       => 'Selecting marks rewrote a Tableau set that calcs referenced.',
    'zone-visibility'  => 'Tableau showed/hid dashboard zones based on a parameter or field value.',
    'drill-hierarchy'  => 'Field hierarchies let users expand dimensions level by level.',
    'custom-tooltip'   => 'These sheets carry customized tooltips (extra fields and/or an embedded viz).',
    'show-hide-button' => 'Dashboard buttons toggled container visibility.',
    'nav-button'       => 'Dashboard button objects.',
    'export-button'    => 'Dashboard buttons exported the view as a file.',
    'integer-dim-decode' => 'The source filters an INTEGER-coded dimension (e.g. STORE_KEY). ' \
      "A Sigma list control sources STRING option values, so a filter target on the raw integer column is " \
      'accepted then SILENTLY stripped (the control filters nothing). The migration auto-decodes most of these ' \
      'via a Text() helper column; the ones below could NOT be auto-built (e.g. the column lives only on a ' \
      'hidden master with a cross-scope issue) and need a Text() decode added by hand.'
  }.freeze

  def status_badge(s)
    "**Sigma status:** #{STATUS_LABEL[s] || s}"
  end

  def describe_targets(entry)
    ts = entry['targets'] || []
    return nil if ts.empty?
    ts.map do |t|
      if t['dashboard'] && t['sheets']
        pg = t['sigma_page'] ? " → Sigma page '#{t['sigma_page']}'" : ''
        "dashboard '#{t['name']}'#{pg} (#{t['sheets'].empty? ? 'no sheet zones' : cap_list(t['sheets'], 8)})"
      elsif t['dashboard']
        pg = t['sigma_page'] ? " → Sigma page '#{t['sigma_page']}'" : ''
        "dashboard '#{t['name']}'#{pg}"
      elsif t['parameter']
        c = t['sigma_control'] ? " → Sigma control '#{t['sigma_control']}'" : ''
        "parameter '#{t['name']}'#{c}"
      elsif t['set']
        "set '#{t['name']}'"
      else
        el = t['sigma_element'] ? " (Sigma: '#{t['sigma_element']}')" : ''
        "#{t['name']}#{el}"
      end
    end.join('; ')
  end

  def render_guide(entries, opts)
    md = String.new
    md << "# Post-publish interactivity guide — #{opts[:workbook_name]}\n\n"
    md << "**Sigma workbook:** #{opts[:sigma_url]}\n\n" if opts[:sigma_url]
    md << "_Generated by `build-postpublish-guide.rb` from `#{File.basename(opts[:twb])}`._\n\n"

    if entries.empty?
      md << "No interactive actions detected in the Tableau source — no dashboard\n"
      md << "actions, parameter actions, dynamic zone visibility, drill hierarchies,\n"
      md << "custom tooltips, or dashboard buttons. Nothing to wire up post-publish.\n"
      return md
    end

    md << "The interactions below exist in the Tableau source but **cannot be expressed\n"
    md << "in Sigma's workbook spec today** — the published workbook has the data, charts,\n"
    md << "and controls, but this wiring must be added in the Sigma UI (or accepted as a\n"
    md << "gap). Each section explains what the Tableau source did and gives the exact\n"
    md << "Sigma UI steps to add the interaction; where Sigma has no equivalent, it names\n"
    md << "the closest pattern instead of pretending. Work through the checklist at the\n"
    md << "end and tick each row as you go.\n\n"

    groups = entries.group_by { |e| e['kind'] }
    ordered = SECTION_ORDER.select { |k| groups.key?(k) }

    # Summary table
    md << "## Summary\n\n"
    md << "| Interaction | Count | Sigma status |\n|---|---|---|\n"
    ordered.each do |k|
      statuses = groups[k].map { |e| STATUS_LABEL[e['sigma_status']] }.uniq.join(' / ')
      md << "| #{SECTION_TITLE[k]} | #{groups[k].length} | #{statuses} |\n"
    end
    md << "\n"

    sec = 0
    sec_no = {}
    ordered.each do |kind|
      sec += 1
      sec_no[kind] = sec
      rows = groups[kind]
      md << "## #{sec}. #{SECTION_TITLE[kind]} (#{rows.length})\n\n"
      md << "#{SECTION_INTRO[kind]}\n\n"

      if kind == 'custom-tooltip'
        md << render_tooltip_section(rows)
        next
      end

      rows.each_with_index do |e, i|
        title = e['caption'].to_s.empty? ? SECTION_SINGULAR[kind] : e['caption']
        md << "### #{sec}.#{i + 1} #{title}\n\n"
        src = e['source'] || {}
        what = String.new("- **Tableau:** #{src['description'] || '(source unknown)'}")
        what << " — trigger: #{e['trigger']}" if e['trigger']
        tgt = describe_targets(e)
        what << " → #{tgt}" if tgt
        md << what << "\n"
        md << "- **Fields:** #{cap_list(e['fields'], 8)}\n" if e['fields'] && !e['fields'].empty?
        if e['url_template']
          md << "- **Tableau URL template:** `#{e['url_template']}`\n"
          md << "- **Sigma URL formula:** `#{e['sigma_formula']}`\n" if e['sigma_formula']
        end
        md << "- #{status_badge(e['sigma_status'])}\n"
        md << "- **Steps:** #{e['ui_steps']}\n" unless e['ui_steps'].to_s.empty?
        (e['notes'] || []).each { |n| md << "- Note: #{n}\n" }
        md << "\n"
      end
    end

    # Final checklist — one row per interaction (tooltips aggregated: reviewing
    # N tooltips is one work item, not N).
    md << "## Checklist\n\n"
    md << "| Done | Interaction | Action | Target |\n|---|---|---|---|\n"
    ordered.each do |kind|
      rows = groups[kind]
      if kind == 'custom-tooltip'
        names = rows.map { |e| e['caption'] }
        md << "| ☐ | Custom tooltips | Rebuild tooltips on #{rows.length} sheet(s) (see §#{sec_no[kind]}) | #{cap_list(names, 6)} |\n"
        next
      end
      rows.each do |e|
        label = e['caption'].to_s.empty? ? SECTION_TITLE[kind] : e['caption']
        act =
          case e['sigma_status']
          when STATUS_UI    then 'Add in Sigma UI'
          when STATUS_BUILT then 'Verify built control'
          else                   'Review closest pattern / accept gap'
          end
        md << "| ☐ | #{SECTION_SINGULAR[kind]}: #{label} | #{act} | #{describe_targets(e) || '—'} |\n"
      end
    end
    md << "\n_Every UI instruction above is either a verified step pattern or marked\n"
    md << "\"verify in your Sigma version\". If a step doesn't match your Sigma build,\n"
    md << "check Sigma's release notes rather than improvising._\n"
    md
  end

  # Tooltips render as one compact table (a workbook can carry dozens).
  TOOLTIP_TABLE_CAP = 40
  def render_tooltip_section(rows)
    md = String.new
    md << "| Sheet | Tooltip fields | Embedded viz | Sigma status |\n|---|---|---|---|\n"
    rows.first(TOOLTIP_TABLE_CAP).each do |e|
      md << "| #{e['caption']} | #{cap_list(e['fields'], 6)} | #{e['viz_in_tooltip'] ? 'yes — no Sigma equivalent' : 'no'} | #{STATUS_LABEL[e['sigma_status']]} |\n"
    end
    md << "| _…and #{rows.length - TOOLTIP_TABLE_CAP} more_ | | | |\n" if rows.length > TOOLTIP_TABLE_CAP
    md << "\n**Steps (field tooltips):** #{STEPS_TOOLTIP}\n"
    if rows.any? { |e| e['viz_in_tooltip'] }
      md << "\n**Embedded viz-in-tooltip** has no Sigma equivalent (no spec or UI path to\n"
      md << "embed a chart in a tooltip). Closest: give the embedded viz its own chart and\n"
      md << "wire it from the host element via 'Use as filter'.\n"
    end
    md << "\n"
    md
  end

  # ==== Orchestration ========================================================

  def extract_all(xml, wbids)
    lut        = build_column_lookup(xml)
    dashboards = build_dashboard_index(xml)
    entries = []
    entries.concat extract_action_blocks(xml, lut, dashboards)
    entries.concat extract_nav_actions(xml, dashboards)
    entries.concat extract_parameter_actions(xml, lut)
    entries.concat extract_set_actions(xml, lut)
    entries.concat extract_zone_visibility(xml, lut, dashboards)
    entries.concat extract_drill_paths(xml, lut)
    entries.concat extract_tooltips(xml, lut, dashboards)
    entries.concat extract_buttons(xml, dashboards)
    enrich_with_wb_ids(entries, wbids)
  end

  # PR-18: manual-decode notes for integer-coded dimension filters build-charts
  # could NOT auto-decode. Read from <workdir>/integer-dim-decode.json (emitted
  # next to the twb) so a filter that would otherwise ship SILENTLY STRIPPED is
  # routed here instead of dropped. Auto-decoded controls need no note.
  def extract_integer_dim_manual(twb_path)
    dir = File.dirname(File.expand_path(twb_path))
    path = File.join(dir, 'integer-dim-decode.json')
    return [] unless File.exist?(path)
    doc = JSON.parse(File.read(path)) rescue (return [])
    Array(doc['manual']).map do |m|
      col = m['column'] || m['name']
      { 'kind' => 'integer-dim-decode', 'caption' => (m['name'] || col).to_s,
        'sigma_status' => STATUS_NONE,
        'source' => { 'description' => "Tableau quick filter on integer-coded dimension #{col.inspect}" },
        'ui_steps' => "In the Sigma workbook, add a hidden column `Text([#{col}])` on the table the " \
                      "control targets (the master or the base table the charts source through), then set " \
                      "the list control's value-source AND its filter target to that decoded column. A raw " \
                      'numeric list-filter target is accepted then silently stripped by Sigma.',
        'notes' => Array(m['notes']) }
    end
  end

  # Workbook display name: the .twb is almost always downloaded as
  # workbook-content.twb inside a per-workbook workdir, so the directory name is
  # the meaningful handle; a differently-named .twb names itself.
  def workbook_name(twb_path)
    base = File.basename(twb_path, '.*')
    base =~ /\Aworkbook-content\z/i ? File.basename(File.dirname(File.expand_path(twb_path))) : base
  end

  def run(argv)
    opts = {}
    OptionParser.new do |p|
      p.banner = 'usage: build-postpublish-guide.rb --twb <workbook-content.twb> --out <workdir>/POSTPUBLISH_GUIDE.md [--wb-ids wb-ids.json] [--json-out out.json] [--sigma-url URL]'
      p.on('--twb PATH')       { |v| opts[:twb] = v }
      p.on('--out PATH')       { |v| opts[:out] = v }
      p.on('--wb-ids PATH')    { |v| opts[:wb_ids] = v }
      p.on('--json-out PATH')  { |v| opts[:json_out] = v }
      p.on('--sigma-url URL')  { |v| opts[:sigma_url] = v }
    end.parse!(argv)
    abort('missing --twb')  unless opts[:twb]
    abort('missing --out')  unless opts[:out]
    abort("not found: #{opts[:twb]}") unless File.exist?(opts[:twb])

    xml   = TwbXml.parse(File.read(opts[:twb], encoding: 'UTF-8'))
    wbids = load_wb_ids(opts[:wb_ids])
    entries = extract_all(xml, wbids)
    entries.concat(extract_integer_dim_manual(opts[:twb])) # PR-18 manual-decode notes

    opts[:workbook_name] = workbook_name(opts[:twb])
    File.write(opts[:out], render_guide(entries, opts))
    warn "wrote #{opts[:out]} (#{entries.length} interaction(s): " +
         (entries.empty? ? 'none detected' :
          entries.group_by { |e| e['kind'] }.map { |k, v| "#{v.length} #{k}" }.join(', ')) + ')'

    if opts[:json_out]
      File.write(opts[:json_out], JSON.pretty_generate(entries))
      warn "wrote #{opts[:json_out]}"
    end
    entries
  end
end

PostpublishGuide.run(ARGV) if $PROGRAM_NAME == __FILE__
