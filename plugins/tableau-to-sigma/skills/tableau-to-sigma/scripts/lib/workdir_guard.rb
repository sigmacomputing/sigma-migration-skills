# frozen_string_literal: true
#
# workdir_guard.rb — refuse a migration workdir that lives inside the installed
# plugin (twin: workdir_guard.py).
#
# WHY. AGENTS.md tells an agent to cd into the skill directory before running a
# script. In a real Windows run the agent then also passed that directory (or `.`)
# as --workdir / --tableau-dir, so wb-readback.json, chart-provenance.json, ...
# were written into — and read back from — the INSTALLED plugin
# (~/.claude/plugins/cache/<marketplace>/tableau-to-sigma/<version>/skills/...).
# Two failures follow: a later migration reads a previous migration's stale files
# from the shared install, and the source-object census resolves evidence through
# paths like ../../../../../../.claude/plugins/cache/....
#
# WHAT IS REFUSED (after realpath — symlinks and `.` resolve first; compared
# case-insensitively on Windows/macOS): the skill directory, the plugin root, or
# anything inside either; and any `.claude/plugins/{cache,marketplaces}` path.
# The workdir may not exist yet; its deepest existing ancestor is resolved.
#
# Escape hatch: SIGMA_ALLOW_WORKDIR_IN_SKILL=1 (only for developing the skill
# itself — never for a real migration).
#
# Usage (at the point the flag is parsed):
#   require_relative 'lib/workdir_guard'
#   o.on('--workdir DIR') { |v| opts[:dir] = WorkdirGuard.check!(v, '--workdir') }
# check! returns its argument unchanged, or prints the reason and exits 2.
# check_file! does the same for an output FILE path (guards its directory).

require 'rbconfig'

module WorkdirGuard
  ESCAPE_ENV = 'SIGMA_ALLOW_WORKDIR_IN_SKILL'
  EXIT_CODE = 2
  # Where the skill lives: <plugin>/skills/<skill>/scripts/lib/workdir_guard.rb
  SKILL_DIR = File.expand_path('../..', __dir__)

  module_function

  def case_insensitive?
    RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin|darwin/i ? true : false
  end

  # Existing-prefix realpath: resolves symlinks and `..` for the part of the path
  # that exists, then re-appends the not-yet-created tail.
  def resolve(path)
    abs = File.expand_path(path.to_s)
    tail = []
    cur = abs
    until File.exist?(cur)
      parent = File.dirname(cur)
      break if parent == cur
      tail.unshift(File.basename(cur))
      cur = parent
    end
    base = begin
      File.realpath(cur)
    rescue SystemCallError
      cur
    end
    File.join(base, *tail).tr('\\', '/')
  end

  def norm(path)
    p = path.to_s.tr('\\', '/').sub(%r{/+\z}, '')
    case_insensitive? ? p.downcase : p
  end

  def inside?(path, root)
    p = norm(path)
    r = norm(root)
    !r.empty? && (p == r || p.start_with?("#{r}/"))
  end

  # The skill dir, plus the plugin root when the layout is <plugin>/skills/<skill>.
  # Only when this really IS a skill dir (SKILL.md present): a script copied into
  # an arbitrary layout (a test tmpdir, ~/bin) must not turn its grandparent into
  # a protected tree. The .claude/plugins path rule below still applies.
  def protected_roots
    return [] unless File.file?(File.join(SKILL_DIR, 'SKILL.md'))
    roots = [SKILL_DIR]
    parent = File.dirname(SKILL_DIR)
    roots << File.dirname(parent) if File.basename(parent) == 'skills'
    roots.flat_map { |r| [File.expand_path(r), resolve(r)] }.uniq
  end

  # `.claude/plugins/cache/...` or `.claude/plugins/marketplaces/...` (also under
  # CLAUDE_CONFIG_DIR), matched on path segments.
  def plugin_install_path?(path)
    segs = norm(path).split('/')
    segs.each_index do |i|
      next unless segs[i] == '.claude' && segs[i + 1] == 'plugins'
      return true if %w[cache marketplaces].include?(segs[i + 2])
    end
    cfg = ENV['CLAUDE_CONFIG_DIR'].to_s
    return false if cfg.empty?
    %w[cache marketplaces].any? { |d| inside?(path, File.join(resolve(cfg), 'plugins', d)) }
  end

  # nil when `path` is acceptable, else a one-line reason.
  def violation(path)
    return nil if path.nil? || path.to_s.strip.empty?
    expanded = File.expand_path(path.to_s)
    real = resolve(path)
    protected_roots.each do |root|
      return "#{path.inspect} resolves to #{real}, inside the installed skill/plugin (#{root})" if inside?(real, root) || inside?(expanded, root)
    end
    if plugin_install_path?(real) || plugin_install_path?(expanded)
      return "#{path.inspect} resolves to #{real}, inside a .claude/plugins cache/marketplace install"
    end
    nil
  end

  def message(path, label, reason)
    fix_flag = label.start_with?("-") ? "#{label.split(" ").first} " : ""
    <<~MSG
      REFUSED: #{label} #{reason}.
        Run artifacts (wb-readback.json, chart-provenance.json, ...) must never be written into, or
        read back from, the installed plugin: a later migration would pick up this one's stale
        files, and the source-object census would resolve evidence through the plugin cache.
        Fix: use a workdir OUTSIDE the plugin, e.g. #{fix_flag}~/tableau-migration/<name>
        (cd into the skill dir to run scripts if you like, but never use it, or `.`, as the workdir).
    MSG
  end

  def check!(path, label = '--workdir')
    return path if ENV[ESCAPE_ENV] == '1'
    reason = violation(path)
    return path unless reason
    warn message(path, label, reason)
    exit EXIT_CODE
  end

  # An output FILE path: its directory is what must stay out of the install.
  def check_file!(path, label = '--out')
    return path if path.nil? || path.to_s.strip.empty?
    check!(File.dirname(File.expand_path(path.to_s)), label)
    path
  end
end
