# frozen_string_literal: true
#
# button_fallback.rb — keep a workbook POST/PUT alive in a workspace where
# Sigma `button` elements are switched off, and own the one text-pill shape a
# Tableau navigation button degrades to.
#
# Two kinds of button can be rewritten to text on that error:
#   * Info-icon sheets (a Tableau Shape mark whose only content is a customized
#     tooltip) are emitted as icon-only buttons whose `text` is the hover
#     tooltip. The popup becomes inline text — degraded, never dropped.
#   * Navigation buttons (dashboard-object `navigate` zones) are emitted as
#     native buttons with ONE on-click `navigate` action to a page. They become
#     the text pill the builder's opt-out mode (SIGMA_BUTTON_ELEMENTS=off) emits:
#     a bold markdown link to the https://nav.invalid/#page=<name> placeholder,
#     which put-layout.rb rewrites to a live `?:nodeId=` link after publish.
#     build-charts-from-signals.rb and this fallback both build that pill through
#     nav_pill, so the two shapes cannot drift.
#
# Buttons are spec-valid everywhere, but some workspaces reject them at write
# time (live-probed 2026-07-11: verify 200, PUT 400 "`button` elements are not
# enabled for this workspace"). One gated element must not fail the whole
# workbook, so on THAT error the caller rewrites those buttons and re-sends once.
# Buttons with any other action (writeback etc.) have no text equivalent and are
# left for the API to reject loudly.
#
# Pure: no I/O. Unit-tested by test-button-fallback.rb; used by
# post-and-readback.rb.
require 'erb'

module ButtonFallback
  module_function

  GATED_RE = /`?button`?\s+elements?\s+(?:are|is)\s+not\s+enabled/i.freeze

  def gated_error?(body)
    !!(body.to_s =~ GATED_RE)
  end

  # SIGMA_BUTTON_ELEMENTS=off|0|false forces the text-pill form up front (for a
  # workspace known to gate buttons, saving the rejected first write). Anything
  # else — unset, `on`, a typo — emits native buttons.
  def native_buttons?(env_value = ENV['SIGMA_BUTTON_ELEMENTS'])
    !%w[off 0 false].include?(env_value.to_s.strip.downcase)
  end

  # The machine-recognizable placeholder put-layout.rb rewrites to the live
  # workbook page URL once the workbook (and so its URL) exists.
  def nav_placeholder_url(page_name)
    "https://nav.invalid/#page=#{ERB::Util.url_encode(page_name)}"
  end

  # The text-pill a navigation button degrades to: bold markdown link in a
  # centered paragraph, with the pill background when the button had a fill.
  # kind:text cannot host actions[], so the link carries the placeholder URL.
  # verticalAlign uses the legacy `middle` spelling; Sigma::CodeRep.wrap
  # canonicalizes it on every write boundary.
  def nav_pill(id, label, page_name, fill_color = nil)
    body = "[**#{label}**](#{nav_placeholder_url(page_name)})"
    body = %(<span style="background-color: #{fill_color[0, 7]}">#{body}</span>) if fill_color
    { 'id' => id, 'kind' => 'text',
      'body' => %(<p style="text-align: center">#{body}</p>), 'verticalAlign' => 'middle' }
  end

  # An info-icon button: no actions, an emoji icon. Buttons that carry other
  # actions (writeback) have no text equivalent and are left for the API to
  # reject loudly.
  def info_icon?(el)
    el.is_a?(Hash) && el['kind'] == 'button' && Array(el['actions']).empty? &&
      el['icon'].is_a?(Hash) && el['icon']['type'] == 'emoji'
  end

  # A navigation button: exactly one on-click action with exactly one `navigate`
  # effect to a page. Anything richer (extra actions or effects, other effect
  # kinds) is left alone.
  def nav_button?(el)
    return false unless el.is_a?(Hash) && el['kind'] == 'button'
    actions = Array(el['actions'])
    return false unless actions.size == 1 && actions[0].is_a?(Hash) && actions[0]['trigger'] == 'on-click'
    effects = Array(actions[0]['effects'])
    effects.size == 1 && effects[0].is_a?(Hash) && effects[0]['effect'] == 'navigate' &&
      effects[0]['target'].is_a?(Hash) && effects[0]['target']['type'] == 'page'
  end

  def text_for(el)
    emoji = el.dig('icon', 'emoji').to_s
    lines = el['text'].to_s.split("\n")
    body = lines.map { |l| l.strip.empty? ? '' : l }.join("\n\n").gsub(/\n{3,}/, "\n\n")
    { 'id' => el['id'], 'kind' => 'text', 'body' => [emoji, body].reject(&:empty?).join(' ') }
  end

  # page id => page name from a wrapped (`document.pages`) or flat (`pages`)
  # workbook body.
  def page_names(doc)
    return {} unless doc.is_a?(Hash)
    pages = doc['document'].is_a?(Hash) && doc['document']['pages'] ? doc['document']['pages'] : doc['pages']
    Array(pages).each_with_object({}) do |pg, names|
      names[pg['id']] = pg['name'] if pg.is_a?(Hash) && pg['id'] && pg['name']
    end
  end

  # The pill for one navigation button. The target page NAME comes from the body's
  # pages (id => name). When the id resolves to nothing — the builder's
  # provisional `page-<slug>` guess never matched a real page — the button's own
  # text stands in as the name. Returns [pill, record]; record['resolved'] is
  # false for that fallback.
  def nav_pill_for(el, names)
    target = el['actions'][0]['effects'][0]['target']['page']
    name = names[target]
    resolved = !name.to_s.strip.empty?
    name = el['text'].to_s unless resolved
    [nav_pill(el['id'], el['text'].to_s, name, el['fillColor']),
     { 'id' => el['id'], 'action_id' => el['actions'][0]['id'], 'page' => name, 'resolved' => resolved }]
  end

  # Rewrites info-icon buttons and navigation buttons in place anywhere in the
  # (wrapped or flat) workbook body. Returns every id rewritten; `nav` receives
  # one record per navigation button ({id, action_id, page, resolved}) so the
  # caller can log it and retire the matching actions-emitted manifest entries.
  def rewrite!(node, rewritten = [], nav = [], names = nil)
    names ||= page_names(node)
    case node
    when Hash
      node.each_value { |v| rewrite!(v, rewritten, nav, names) }
    when Array
      node.map! do |v|
        if info_icon?(v)
          rewritten << v['id']
          text_for(v)
        elsif nav_button?(v)
          pill, record = nav_pill_for(v, names)
          rewritten << v['id']
          nav << record
          pill
        else
          rewrite!(v, rewritten, nav, names)
          v
        end
      end
    end
    rewritten
  end

  # Entries of an actions-emitted manifest minus the ones whose actionId was
  # downgraded. Returns [kept, removed].
  def prune_manifest(entries, action_ids)
    Array(entries).partition { |m| !(m.is_a?(Hash) && action_ids.include?(m['actionId'])) }
  end
end
