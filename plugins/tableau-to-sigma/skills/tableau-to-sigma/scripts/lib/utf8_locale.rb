# frozen_string_literal: true

# utf8_locale.rb — make every child process inherit a UTF-8 locale.
#
# `Encoding.default_external = UTF_8` fixes only THIS Ruby process. Ruby/Python
# children spawned at --finalize (assert-phase6-ran, verify-*, py scripts)
# inherit the environment, and with LANG unset they default to US-ASCII and die
# on the first non-ASCII byte in a spec/CSV (field case: --finalize crashed
# with a US-ASCII encoding error unless LANG=en_US.UTF-8 was exported).
#
# Detection mirrors corpus/run-corpus.sh: prefer C.UTF-8 (no locale generation
# needed), else en_US.UTF-8, taken from ONE `locale -a` capture.
module Utf8Locale
  UTF8_RE = /utf-?8/i.freeze
  PREFERRED = %w[C.UTF-8 en_US.UTF-8].freeze

  module_function

  # The locale a child would actually use: LC_ALL > LC_CTYPE > LANG.
  def effective(env = ENV)
    %w[LC_ALL LC_CTYPE LANG].each do |k|
      v = env[k].to_s
      return v unless v.empty?
    end
    ''
  end

  def utf8?(env = ENV)
    effective(env).match?(UTF8_RE)
  end

  def installed_locales
    `locale -a 2>/dev/null`.to_s.split("\n").map(&:strip)
  rescue StandardError
    []
  end

  # Pure picker (testable): first PREFERRED locale present in `available`
  # (compared loosely: "en_US.utf8" == "en_US.UTF-8").
  def pick(available)
    norm = ->(l) { l.to_s.downcase.delete('-') }
    have = available.map { |l| norm.call(l) }
    PREFERRED.find { |p| have.include?(norm.call(p)) }
  end

  # Sets LANG + LC_ALL (and Python's UTF-8 switches) in env when the effective
  # locale is not UTF-8. Returns the locale it set, :already, or nil when no
  # UTF-8 locale is installed (nothing to set; Python switches still apply).
  def ensure!(env = ENV, available: nil)
    env['PYTHONUTF8'] ||= '1'
    env['PYTHONIOENCODING'] ||= 'utf-8'
    return :already if utf8?(env)
    loc = pick(available || installed_locales)
    return nil unless loc
    env['LANG'] = loc
    env['LC_ALL'] = loc
    loc
  end
end
