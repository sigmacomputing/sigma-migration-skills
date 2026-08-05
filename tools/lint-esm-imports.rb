#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-esm-imports.rb — CI gate for the Windows ESM-path footgun (#348).
#
# A migrate/convert script that writes or runs an ESM shim importing the vendored
# converter by ABSOLUTE PATH must turn that path into a file:// URL first, or
# Node's ESM loader rejects it on Windows with
#   ERR_UNSUPPORTED_ESM_URL_SCHEME ... Received protocol 'c:'
# A POSIX absolute path happens to import on macOS/Linux, so the bug is INVISIBLE
# on the dev box — exactly how #348 shipped in every powerbi/qlik/quicksight/
# looker/thoughtspot converter at once. This flags any ESM import built from a
# path variable (or an absolute-path literal) in a file that lacks a file://-URL
# guard, so that blind spot can't return.
#
# The proven guards (any one satisfies the check for the whole file):
#   Ruby   `if Gem.win_platform? ... 'file:///' + path.gsub('\\','/')`  (-> file:///)
#   Node   `await import(pathToFileURL(CONV).href)`                     (-> pathToFileURL)
#   Python `pathlib.Path(build).resolve().as_uri()`                     (-> .as_uri()
#
#   ruby tools/lint-esm-imports.rb        # non-zero on an unguarded import
#
# Creds-free, stdlib-only — safe for the corpus-check workflow.

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# NB: fileURLToPath is deliberately NOT a guard — thoughtspot imported it (for
# its own __dirname) yet still did a bare `import(CONV)`; only pathToFileURL /
# file:/// / .as_uri() actually rewrite the specifier.
GUARDS = ['pathToFileURL', 'file:///', '.as_uri('].freeze

def offending?(path, line)
  if path.end_with?('.rb')
    # ESM import in a Ruby heredoc, built from an interpolated variable:
    #   import { convertXToSigma } from #{CONV_MODULE.to_json};
    line =~ /import\s*(\{[^}]*\}\s*from\s*)?\#\{/ && line =~ /import/
  elsif path.end_with?('.py')
    # ESM import in a generated (f-string) shim: from {json.dumps(build)}
    line =~ /import\s+\{\{[^}]*\}\}\s+from\s+\{/
  else # .mjs
    # dynamic import of a BARE identifier: await import(CONV)
    line =~ /\bimport\s*\(\s*[A-Za-z_$][\w$]*\s*\)/ ||
      # OR a static import from an ABSOLUTE-path literal (bare drive / POSIX root)
      line =~ %r{^\s*import\s+.*\sfrom\s+["'](/[^"']*|[A-Za-z]:[\\/][^"']*)["']}
  end
end

fails = [] # [path, lineno, snippet]

Dir.glob('{plugins,shared}/**/*.{rb,mjs,py}').sort.each do |f|
  next if f.include?('/node_modules/') || f.include?('/converter/') || f.include?('/dist/')
  body = File.read(f)
  next if GUARDS.any? { |g| body.include?(g) } # file carries a file://-URL guard
  File.foreach(f).with_index do |line, i|
    next if line =~ /\A\s*(#|\/\/)/ # skip comments
    fails << [f, i + 1, line.strip[0, 90]] if offending?(f, line)
  end
end

if fails.empty?
  puts 'OK: no unguarded absolute-path ESM imports (Windows file:// footgun, #348).'
  exit 0
end

puts 'ESM IMPORT PORTABILITY FAILURE'
puts 'An ESM shim imports the converter by absolute path without a file:// URL —'
puts "Node rejects that on Windows (ERR_UNSUPPORTED_ESM_URL_SCHEME). Guard it with"
puts 'pathToFileURL(...).href (Node), Gem.win_platform?+file:/// (Ruby), or Path.as_uri() (Python).'
puts
fails.each { |f, ln, snip| puts "  FAIL  #{f}:#{ln} — #{snip}" }
puts
puts "failures: #{fails.size}"
exit 1
