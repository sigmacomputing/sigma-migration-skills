# frozen_string_literal: true

# Plugin-local twin of the "explicit SIGMA_CLI_PROFILE pins the org" rule the
# shared Ruby client (lib/sigma_rest.rb) evaluates inline at require time.
#
# An explicit profile chooses the Sigma org and its host, so nothing may copy the
# settings file's org-selecting keys (base URL, client credentials) into the
# environment afterwards. migrate-tableau.rb's credential gate refills those keys
# from ~/.sigma-migration/env when they are empty; it asks this module first.
#
# "Pinned" = SIGMA_CLI_PROFILE (stripped) is non-empty AND differs from
# SIGMA_CLI_PROFILE_FROM_FILE (the value an earlier loader copied from the file)
# AND differs from the settings file's own SIGMA_CLI_PROFILE (that one key, last
# assignment wins, quotes stripped). Comparisons are case-sensitive. Same line
# grammar as the shared loader.
module SigmaProfilePin
  module_function

  # The settings file's own SIGMA_CLI_PROFILE value ('' if none / unreadable).
  def settings_file_profile(path)
    value = ''
    File.foreach(path, encoding: 'UTF-8') do |line|
      next unless (m = line.chomp.match(/\A\s*(?:export\s+)?SIGMA_CLI_PROFILE=(.*)\z/))
      raw = m[1].strip
      raw = raw[1..-2] if raw.length >= 2 &&
        ((raw.start_with?("'") && raw.end_with?("'")) || (raw.start_with?('"') && raw.end_with?('"')))
      value = raw.strip
    end
    value
  rescue SystemCallError
    ''
  end

  # env: any Hash-like (ENV by default); path is read at call time.
  def pinned?(env = ENV, path = File.expand_path('~/.sigma-migration/env'))
    profile = env['SIGMA_CLI_PROFILE'].to_s.strip
    return false if profile.empty?
    return false if profile == env['SIGMA_CLI_PROFILE_FROM_FILE'].to_s.strip

    profile != settings_file_profile(path)
  end
end
