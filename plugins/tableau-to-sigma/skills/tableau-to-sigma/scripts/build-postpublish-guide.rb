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
#     [--emitted-manifest /tmp/<name>/chart-specs-actions-emitted.json]  # what build-charts-from-signals.rb already auto-wired
#     [--json-out /tmp/<name>/action-ledger.json]  # CONTRACTUAL path — gate 11 reads <workdir>/action-ledger.json
#     [--sigma-url https://app.sigmacomputing.com/.../workbook/...]
#
# DETECT-ONLY MODE (--detect-only PATH): runs the SAME extract_* detection
# from --twb alone and writes the raw detected-entries ARRAY to PATH, then
# exits — no POSTPUBLISH_GUIDE.md, no --json-out, no ledger of any kind.
# Detection only needs the .twb (which lands well before chart build), while
# --wb-ids/--sigma-url are optional POST-PUBLISH enrichment — so migrate-
# tableau.rb can run this pass EARLY, before build-charts-from-signals.rb, and
# hand it the array via that script's --detected-actions flag. This is the
# bridge between this script's DETECTION half and build-charts-from-signals.rb's
# EMISSION half; it does not itself emit or auto-wire anything.
#   ruby scripts/build-postpublish-guide.rb --twb /tmp/<name>/workbook-content.twb \
#     --detect-only /tmp/<name>/detected-actions.json
#
# CRITICAL: --detect-only must NEVER write action-ledger.json or anything
# ledger-shaped ({schemaVersion, detectedCount, emitted, residue}). Gate 11
# reads <workdir>/action-ledger.json and asserts conservation over it; an
# early half-ledger with `emitted: []` (nothing auto-wired YET, because the
# chart build hasn't run) would be read as the AUTHORITATIVE final ledger —
# exactly the failure mode this mode must avoid. The bare array has no such
# authority.
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
# JSON sidecar (--json-out): the ACTION LEDGER object
# {schemaVersion, detectedCount, emitted, residue} — not a bare entries
# array. `emitted` echoes back whatever --emitted-manifest supplied (the
# actions-emitted.json sidecar from build-charts-from-signals.rb, when the
# converter auto-wired some of them); `residue` is every detected
# interaction {kind, caption, source, targets, fields, ui_steps, notes, ...}
# that was NOT already auto-wired — this is exactly what render_guide renders
# and what downstream tooling / the conversion report should read, which
# must LINK the guide (refs/postpublish-interactivity.md).

require 'json'
require 'optparse'
require 'uri'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
require 'action_ledger'
require 'workbook_code'

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

  # ---- Status is derived, not asserted -------------------------------------
  # Every extract_* method used to hardcode 'sigma_status' on each entry it
  # built. That was a per-KIND classification masquerading as a per-entry
  # fact, and it had nothing to do with whether THIS SPECIFIC action was
  # actually auto-wired by the converter (the ActionLedger join, driven by
  # --emitted-manifest, is what answers that). Only entries that survive the
  # join as residue ever reach render_guide, so "status" here answers a
  # narrower, honest question: for interactions Sigma can't auto-wire, is
  # there a UI path, an already-built control equivalent, or no equivalent at
  # all? That answer is constant per KIND for every extractor except
  # custom-tooltip, whose status depends on whether THIS tooltip embeds a
  # viz (see extract_tooltips' 'viz_in_tooltip' flag).
  KIND_STATUS = {
    'filter-action'      => STATUS_UI,
    'highlight-action'   => STATUS_NONE,
    'url-action'         => STATUS_UI,
    'nav-action'         => STATUS_UI,
    'parameter-action'   => STATUS_BUILT,
    'set-action'         => STATUS_NONE,
    'zone-visibility'    => STATUS_NONE,
    'drill-hierarchy'    => STATUS_UI,
    'show-hide-button'   => STATUS_NONE,
    'nav-button'         => STATUS_UI,
    'export-button'      => STATUS_UI,
    'integer-dim-decode' => STATUS_NONE
  }.freeze

  def status_for(entry)
    return entry['viz_in_tooltip'] ? STATUS_NONE : STATUS_UI if entry['kind'] == 'custom-tooltip'
    KIND_STATUS[entry['kind']]
  end

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
  # Current wb-ids uses the workbook code representation: metadata outside,
  # metadata-only document.pages, flat document.elements, and layout-owned page
  # membership. Match Tableau names to the resolved page/element summaries.
  def load_wb_ids(path)
    return nil unless path && File.exist?(path)
    data = JSON.parse(File.read(path))
    pages = WorkbookCode.pages(data)
    elements = []
    pages.each do |pg|
      WorkbookCode.elements_for_page(data, pg).each do |el|
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
  #     'fields' => [...], 'ui_steps' =>, 'notes' => [...],
  #     'actionName' => (when the Tableau action carries a per-instance
  #                       identifier — see ActionLedger.key_of) }
  # No 'sigma_status' here any more — status is derived at render time by
  # status_for(entry), keyed on 'kind' (see KIND_STATUS above). It is not a
  # per-entry fact the extractor asserts.

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
      # `name` is the Tableau <action> element's own `name=` attribute (e.g.
      # "[Action1_AAAA]") — already used above to dedupe; carry it through so
      # ActionLedger.key_of can disambiguate two actions that happen to share
      # a kind+caption instead of colliding on [kind, caption] alone.
      entry['actionName'] = name unless name.empty?

      case kind
      when 'filter-action'
        fields = link_fields(link, lut)
        fields = ['(all shared fields)'] if fields.empty? && params['special-fields'] == 'all'
        entry['fields']  = fields
        entry['targets'] = expand_target(params['target'], params['exclude'], dashboards)
        entry['ui_steps'] = STEPS_USE_AS_FILTER
        entry['notes'] << "Applies element-to-element filters; verify the join columns match the Tableau action's field mapping."
      when 'highlight-action'
        fields = (params['field-captions'] || '').split(',').map { |f| tidy_name(f) }.reject(&:empty?)
        entry['fields']  = fields
        entry['targets'] = expand_target(params['target'], params['exclude'], dashboards)
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
      entry = {
        'kind'    => 'nav-action',
        'caption' => a.attributes['caption'].to_s,
        'source'  => parse_source(a),
        'trigger' => activation_of(a),
        'targets' => [{ 'name' => target_sheet, 'dashboard' => is_dash }],
        'fields'  => [],
        'ui_steps' => STEPS_BUTTON_NAV,
        'notes'   => []
      }
      entry['actionName'] = name unless name.empty?
      out << entry
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
      entry = {
        'kind'      => 'parameter-action',
        'caption'   => a.attributes['caption'].to_s,
        'source'    => parse_source(a),
        'trigger'   => activation_of(a),
        'fields'    => [field_caption(src_field, lut)].compact,
        'targets'   => [{ 'name' => field_caption(tgt_param, lut), 'parameter' => true }],
        # RAW refs, alongside the human captions above. field_caption strips the
        # derivation qualifier (none:X:nk) and tidies the name, which is right
        # for rendering and useless for resolution — emission needs to map the
        # Tableau field to an emitted Sigma columnId, and the caption cannot do
        # that. Additive: every rendered surface still reads `fields`/`targets`.
        'sourceFieldRef'     => src_field,
        'targetParameterRef' => tgt_param,
        'ui_steps'  => '',   # filled in by the wb-ids pass / renderer
        'notes'     => []
      }
      entry['actionName'] = name unless name.empty?
      out << entry
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
      entry = {
        'kind'      => 'set-action',
        'caption'   => a.attributes['caption'].to_s,
        'source'    => parse_source(a),
        'trigger'   => activation_of(a),
        'fields'    => [],
        'targets'   => [{ 'name' => field_caption(tgt_set, lut), 'set' => true }],
        'ui_steps'  =>
          'No Sigma sets. Closest pattern: a list control on the same dimension ' \
          'plus a boolean helper column (If(Contains(...))) that downstream calcs reference in place of the set.',
        'notes'     => []
      }
      entry['actionName'] = name unless name.empty?
      out << entry
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
      # No actionName here: a drill-path's `name` is a hierarchy LABEL, not a
      # per-instance action identifier — two different hierarchies (distinct
      # `levels`) can legitimately share one name. extract_drill_paths already
      # dedupes on the compound [name, levels] key above; drill-hierarchy is
      # never auto-emitted by build-charts-from-signals, so it never actually
      # reaches ActionLedger.join, and [kind, caption] is a fine fallback.
      out << {
        'kind'    => 'drill-hierarchy',
        'caption' => name,
        'source'  => { 'description' => 'datasource hierarchy' },
        'trigger' => nil,
        'fields'  => levels,
        'targets' => [],
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
        entry['ui_steps'] =
          'Embedded viz-in-tooltip has no Sigma equivalent. Closest: add the fields to the ' \
          "tooltip (#{STEPS_TOOLTIP.sub(/\.$/, '')}) and give the embedded viz its own chart, " \
          "wired via 'Use as filter' from this element."
      else
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
        # Dashboard-object button zones carry NO Tableau `name=` attribute
        # (verified against the schema — only sheet-placeholder zones do), so
        # there is no literal action name to carry through here. The zone id
        # is scoped per-dashboard (Tableau zone ids restart per dashboard —
        # the same reason build-charts-from-signals.rb's emitted_action_index
        # keys on (dashboard, host) instead of host alone), so pair it with
        # the dashboard name for a workbook-wide-unique substitute identity.
        # This is what actually closes the collision the ledger's key_of
        # fix exists for: nav-button is the ONLY kind ActionLedger.join ever
        # sees on the `emitted` side today, so two same-captioned buttons
        # (e.g. two "Home" buttons on different dashboards) MUST disambiguate
        # here or the join can silently drop the unemitted one from residue.
        zone_action_name = "#{dname}::zone-#{z.attributes['id']}"
        btn = z.elements['button']
        if btn.nil?
          next unless z.attributes['type-v2'].to_s == 'button'
          # bare button zone with no <button> payload — surface it generically
          push.call(
            'kind' => 'nav-button', 'caption' => "button zone #{z.attributes['id']}",
            'source' => { 'dashboard' => dname, 'description' => "dashboard '#{dname}'" },
            'trigger' => nil, 'fields' => [], 'targets' => [],
            'actionName' => zone_action_name, 'ui_steps' => STEPS_BUTTON_NAV, 'notes' => []
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
            'actionName' => zone_action_name,
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
            'actionName' => zone_action_name,
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
            'actionName' => zone_action_name,
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
            'clicking the control sets the same value. Click-to-set is auto-wired when the ' \
            'source column resolves; otherwise set the control by hand.'
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
            "workbook for a control replacing '#{pname}'#{hint}. Click-to-set is auto-wired when the " \
            'source column resolves; otherwise set the control by hand.'
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

  # Invisible (HTML-comment) machine-readable identity marker for the
  # guide-residue gate (scripts/lib/action_gates.rb#guide_residue_violations).
  # Stamped on every rendered residue entry so that gate can verify
  # structurally which detected action each section corresponds to, instead
  # of scanning the human-readable prose for a caption substring — a caption
  # can legitimately recur in unrelated prose (e.g. an uncaptioned nav-button
  # whose caption falls back to its target DASHBOARD NAME, which some OTHER
  # action's residue prose also legitimately names — parse_source's "any
  # sheet on dashboard '<name>'"), which made substring matching produce false
  # FAILs on runs that were actually fine. Uses the SAME identity
  # ActionLedger.key_of already computes for ActionLedger.join (actionName-
  # preferred, [kind, caption] fallback), JSON-encoded so the gate can parse
  # it back exactly with no separator-collision risk.
  def ledger_marker(entry)
    key = ActionLedger.key_of(entry)
    return '' if key.nil?
    "<!-- ledger-key: #{JSON.generate(key)} -->\n"
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
      statuses = groups[k].map { |e| STATUS_LABEL[status_for(e)] }.uniq.join(' / ')
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
        md << ledger_marker(e)
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
        md << "- #{status_badge(status_for(e))}\n"
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
          case status_for(e)
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
      md << "| #{e['caption']} | #{cap_list(e['fields'], 6)} | #{e['viz_in_tooltip'] ? 'yes — no Sigma equivalent' : 'no'} | #{STATUS_LABEL[status_for(e)]} |\n"
    end
    md << "| _…and #{rows.length - TOOLTIP_TABLE_CAP} more_ | | | |\n" if rows.length > TOOLTIP_TABLE_CAP
    # Markers go AFTER the whole table (not interleaved between rows) —
    # inserting a non-`|`-prefixed line between table rows ends a Markdown
    # table early, breaking the guide's rendering for a human reader.
    rows.each { |e| md << ledger_marker(e) }
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
      p.banner = 'usage: build-postpublish-guide.rb --twb <workbook-content.twb> --out <workdir>/POSTPUBLISH_GUIDE.md [--wb-ids wb-ids.json] [--json-out out.json] [--emitted-manifest actions-emitted.json] [--sigma-url URL]' \
                 "\n   or: build-postpublish-guide.rb --twb <workbook-content.twb> --detect-only <workdir>/detected-actions.json"
      p.on('--twb PATH')       { |v| opts[:twb] = v }
      p.on('--out PATH')       { |v| opts[:out] = v }
      p.on('--wb-ids PATH')    { |v| opts[:wb_ids] = v }
      p.on('--json-out PATH')  { |v| opts[:json_out] = v }
      p.on('--emitted-manifest PATH',
           'actions-emitted.json from build-charts-from-signals (default: none = nothing auto-emitted)') do |v|
        opts[:emitted_manifest] = v
      end
      p.on('--sigma-url URL')  { |v| opts[:sigma_url] = v }
      p.on('--detect-only PATH',
           'Run detection ONLY from --twb (no --out/--wb-ids/--json-out needed) and write the raw ' \
           'detected-entries ARRAY to PATH, then exit — no guide rendered, no ledger written. Lets an ' \
           'early detection pass hand its array to build-charts-from-signals.rb via --detected-actions.') do |v|
        opts[:detect_only] = v
      end
    end.parse!(argv)
    abort('missing --twb')  unless opts[:twb]
    abort("not found: #{opts[:twb]}") unless File.exist?(opts[:twb])

    xml =
      begin
        TwbXml.parse(File.read(opts[:twb], encoding: 'UTF-8'))
      rescue TwbXml::ParseError => e
        # Abort rather than continue with a partial tree. Every extract_* method
        # would return [] against a recovered stub, and --detect-only's consumer
        # (build-charts-from-signals.rb --detected-actions) cannot tell that
        # apart from a workbook with no actions.
        abort "FATAL: cannot parse #{opts[:twb]}: #{e.message}"
      end
    wbids = load_wb_ids(opts[:wb_ids])

    if opts[:detect_only]
      entries = extract_all(xml, wbids)
      File.write(opts[:detect_only], JSON.pretty_generate(entries))
      warn "wrote #{opts[:detect_only]} (#{entries.length} interaction(s) detected) " \
           '[--detect-only: no POSTPUBLISH_GUIDE.md rendered, no action-ledger.json written]'
      return entries
    end

    abort('missing --out')  unless opts[:out]

    entries = extract_all(xml, wbids)
    entries.concat(extract_integer_dim_manual(opts[:twb])) # PR-18 manual-decode notes

    opts[:workbook_name] = workbook_name(opts[:twb])

    # `read_manifest` returns [] both when --emitted-manifest was never
    # passed AND when the file it points at doesn't exist (e.g. worksheet
    # mode, where build-charts-from-signals.rb never writes the manifest at
    # all because it never attempts the button auto-wiring either) — in both
    # cases "nothing auto-wired" is the correct, honest default.
    emitted = ActionLedger.read_manifest(opts[:emitted_manifest])
    ledger  = ActionLedger.join(detected: entries, emitted: emitted)

    # The guide instructs the human. It must describe ONLY work still to do —
    # an action build-charts-from-signals.rb already auto-wired is done, not
    # a checklist item that tells the customer to redo it by hand.
    File.write(opts[:out], render_guide(ledger['residue'], opts))
    warn "wrote #{opts[:out]} (#{entries.length} interaction(s) detected, " \
         "#{ledger['emitted'].size} already auto-wired, #{ledger['residue'].size} still manual: " +
         (ledger['residue'].empty? ? 'none' :
          ledger['residue'].group_by { |e| e['kind'] }.map { |k, v| "#{v.length} #{k}" }.join(', ')) + ')'

    # The ledger path is CONTRACTUAL: gate 11 reads <workdir>/action-ledger.json.
    # migrate-tableau.rb must invoke this script with
    #   --json-out <workdir>/action-ledger.json
    # --json-out writes the FULL LEDGER OBJECT
    # ({schemaVersion, detectedCount, emitted, residue}), not a bare entries
    # array — Task 6's gates read this shape.
    if opts[:json_out]
      File.write(opts[:json_out], JSON.pretty_generate(ledger))
      warn "wrote #{opts[:json_out]}"
    end
    ledger
  end
end

PostpublishGuide.run(ARGV) if $PROGRAM_NAME == __FILE__
