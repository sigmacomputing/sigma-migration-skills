# frozen_string_literal: true
#
# button_fallback.rb — keep a workbook POST/PUT alive in a workspace where
# Sigma `button` elements are switched off.
#
# Info-icon sheets (a Tableau Shape mark whose only content is a customized
# tooltip) are emitted as icon-only Sigma buttons whose `text` is the hover
# tooltip. Buttons are spec-valid everywhere, but some workspaces reject them at
# write time (live-probed 2026-07-11: verify 200, PUT 400 "`button` elements are
# not enabled for this workspace"). One gated element must not fail the whole
# workbook, so on THAT error the caller rewrites every action-less emoji-icon
# button into a text element carrying the same words and re-sends once. The
# popup becomes inline text — degraded, never dropped.
#
# Pure: no I/O. Unit-tested by test-button-fallback.rb; used by
# post-and-readback.rb.
module ButtonFallback
  module_function

  GATED_RE = /`?button`?\s+elements?\s+(?:are|is)\s+not\s+enabled/i.freeze

  def gated_error?(body)
    !!(body.to_s =~ GATED_RE)
  end

  # An info-icon button: no actions, an emoji icon. Buttons that carry actions
  # (navigation, writeback) have no text equivalent and are left for the API to
  # reject loudly.
  def info_icon?(el)
    el.is_a?(Hash) && el['kind'] == 'button' && Array(el['actions']).empty? &&
      el['icon'].is_a?(Hash) && el['icon']['type'] == 'emoji'
  end

  def text_for(el)
    emoji = el.dig('icon', 'emoji').to_s
    lines = el['text'].to_s.split("\n")
    body = lines.map { |l| l.strip.empty? ? '' : l }.join("\n\n").gsub(/\n{3,}/, "\n\n")
    { 'id' => el['id'], 'kind' => 'text', 'body' => [emoji, body].reject(&:empty?).join(' ') }
  end

  # Rewrites info-icon buttons in place anywhere in the (wrapped or flat)
  # workbook body. Returns the ids rewritten.
  def rewrite!(node, rewritten = [])
    case node
    when Hash
      node.each_value { |v| rewrite!(v, rewritten) }
    when Array
      node.map! do |v|
        if info_icon?(v)
          rewritten << v['id']
          text_for(v)
        else
          rewrite!(v, rewritten)
          v
        end
      end
    end
    rewritten
  end
end
