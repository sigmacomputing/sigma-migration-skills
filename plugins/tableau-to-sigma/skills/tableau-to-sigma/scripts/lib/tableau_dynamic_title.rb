# frozen_string_literal: true

# Converts Tableau's title tokens into Sigma dynamic text.
#
# Tableau serializes a displayed parameter inside a worksheet title as
#   <[Parameters].[Parameter 1 3]>
# and the worksheet's own name as
#   <Sheet Name>
#
# Sigma element titles reference a WORKBOOK control through dynamic text:
#   {{[ctl-param-how-many-weeks]}}
#
# Two rules keep a translated title honest:
#
#   * A Tableau parameter is NOT a worksheet calculated field, so it is resolved
#     against the workbook's `parameters` list. Resolving against calculations
#     alone leaves the raw token in the element name, which Sigma renders
#     literally ("Sales Orders - Last <[Parameters].[Parameter 1 3]> weeks").
#
#   * Workbook dynamic text can only reference a control that exists in the
#     WORKBOOK. It cannot reach a control in a data model, and the converter
#     frequently emits a Tableau parameter as a data-model control only. When
#     the workbook control is absent, the parameter's current value is
#     substituted instead — the value the source title displayed — so the title
#     reads correctly rather than referencing a control that renders nothing.
module TableauDynamicTitle
  PARAMETER_TOKEN = /<\[Parameters?\]\s*\.\s*\[([^\]]+)\]>/i
  SHEET_NAME_TOKEN = /<(Sheet|Page|Workbook|Story|Dashboard)\s+Name>/i
  # Residual Tableau title tokens, for the pre-POST lint. Deliberately narrow:
  # a bracketed token or one of Tableau's title keywords, never bare comparison
  # text such as "A > B".
  RESIDUAL_TOKEN = /<\[[^\]<>]+\](?:\s*\.\s*\[[^\]<>]+\])?>|<(?:Sheet|Page|Workbook|Story|Dashboard)\s+Name>/i

  module_function

  def slug(caption)
    caption.to_s.downcase.gsub(/\W+/, '-').sub(/-\z/, '')
  end

  def control_id(caption)
    "ctl-param-#{slug(caption)}"
  end

  # Tableau writes numeric parameter values as "12" or "0." depending on type;
  # render the trailing-dot form the way the source displayed it.
  def display_value(value)
    text = value.to_s.strip
    return text if text.empty?

    text.sub(/\.0*\z/, '')
  end

  def find_parameter(token, parameters, calculations)
    candidates = Array(parameters) + Array(calculations)
    candidates.find do |candidate|
      next false unless candidate.is_a?(Hash)

      name = candidate['name'].to_s.gsub(/\A\[|\]\z/, '').strip
      caption = candidate['caption'].to_s.strip
      name.casecmp?(token) || caption.casecmp?(token)
    end
  end

  # `control_ids` is the set of controlIds the workbook will actually carry.
  # Passing nil keeps the reference unconditionally (callers that have no
  # control census yet); passing a collection gates the reference on it.
  def translate(title, calculations, parameters: [], control_ids: nil, sheet_name: nil, notes: nil)
    known = control_ids.nil? ? nil : Array(control_ids).map(&:to_s)
    out = title.to_s.gsub(PARAMETER_TOKEN) do |original|
      token = Regexp.last_match(1).to_s.strip
      parameter = find_parameter(token, parameters, calculations)
      caption = parameter && parameter['caption'].to_s.strip
      if caption.nil? || caption.empty?
        Array(notes) << "title parameter token <[Parameters].[#{token}]> matches no known parameter — " \
                        'left in the title for migration review'
        next original
      end

      cid = control_id(caption)
      next "{{[#{cid}]}}" if known.nil? || known.include?(cid)

      value = display_value(parameter['default_value'])
      if value.empty?
        Array(notes) << "title parameter '#{caption}' has no workbook control and no current value — " \
                        'token left in the title for migration review'
        next original
      end
      Array(notes) << "title parameter '#{caption}' resolved to its current value #{value.inspect} — " \
                      'the workbook has no control for it (the converter emits it as a data-model ' \
                      'control, which workbook dynamic text cannot reference); add a workbook control ' \
                      'bound to the data-model control to make the title dynamic again'
      value
    end
    out = out.gsub(SHEET_NAME_TOKEN) { sheet_name.to_s } if sheet_name && !sheet_name.to_s.strip.empty?
    out
  end

  # Residual raw tokens in a built string (the pre-POST lint's input).
  def residual_tokens(text)
    text.to_s.scan(RESIDUAL_TOKEN).map { |match| match.is_a?(Array) ? match.first : match }
  end
end
