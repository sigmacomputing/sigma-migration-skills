# frozen_string_literal: true

# Shape-aware classifier for a stale Power BI Import snapshot versus Sigma's
# live warehouse. Staleness can explain changed measures or additional buckets;
# it must never excuse a different dimension representation/schema.
module PbiStaleParity
  module_function

  ISO_DATE = /\A\d{4}-\d{2}-\d{2}(?:[T ].*)?\z/.freeze
  NUMBER = /\A-?\d+(?:\.\d+)?\z/.freeze

  def dimension_key(value)
    case value
    when Numeric
      [:number, value.to_f]
    else
      text = value.to_s.strip
      if text.match?(ISO_DATE)
        [:date, text[0, 10]]
      elsif text.match?(NUMBER)
        [:number, text.to_f]
      else
        [:text, text]
      end
    end
  end

  def dimension_keys(rows)
    Array(rows).map { |row| dimension_key(Array(row)[0]) }
  end

  # True only when every source bucket still exists at the SAME canonical
  # dimension type/grain. Values may change in either direction because a stale
  # snapshot can include rows later corrected/deleted as well as new rows.
  # Additional Sigma buckets are acceptable; missing source buckets are not.
  def value_only_stale?(expected_rows, actual_rows)
    expected = dimension_keys(expected_rows)
    actual = dimension_keys(actual_rows)
    return false if expected.empty? || actual.empty?
    return false unless expected.all? { |key| actual.include?(key) }

    true
  end
end
