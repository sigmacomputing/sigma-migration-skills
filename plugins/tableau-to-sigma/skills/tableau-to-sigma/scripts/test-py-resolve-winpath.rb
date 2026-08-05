#!/usr/bin/env ruby
# Offline test (bead tt3z.15): PyResolve.winpath converts Git-Bash /c/… POSIX paths
# to native Windows paths so a native Windows Python can open() them, and is a strict
# no-op everywhere else. Runs on macOS/Linux CI by FORCING windows? true; since those
# hosts have no `cygpath`, the Open3 spawn raises and the pure-Ruby fallback is what's
# exercised (the branch Windows-cmd/PowerShell users without cygpath also hit).
require_relative 'lib/py_resolve'

$fail = 0
def ok(d); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{d}"; $fail += 1 unless r; end

# Force Windows semantics on the (non-Windows) test host.
def PyResolve.windows?; true; end

ok('/c/Users/x/f.twbx -> C:\\Users\\x\\f.twbx')      { PyResolve.winpath('/c/Users/x/f.twbx') == 'C:\\Users\\x\\f.twbx' }
ok('/mnt/c/tmp/a.json -> C:\\tmp\\a.json (WSL form)') { PyResolve.winpath('/mnt/c/tmp/a.json') == 'C:\\tmp\\a.json' }
ok('drive letter uppercased')                        { PyResolve.winpath('/d/data/x') == 'D:\\data\\x' }
ok('already-native C:\\ untouched')                  { PyResolve.winpath('C:\\Users\\x') == 'C:\\Users\\x' }
ok('already-native C:/ untouched')                   { PyResolve.winpath('C:/Users/x') == 'C:/Users/x' }
ok('UNC path untouched')                             { PyResolve.winpath('\\\\srv\\share') == '\\\\srv\\share' }
ok('flag (no leading /) untouched')                  { PyResolve.winpath('--out') == '--out' }
ok('relative path untouched')                        { PyResolve.winpath('views/a.csv') == 'views/a.csv' }
ok('bare id untouched')                              { PyResolve.winpath('wb-1234') == 'wb-1234' }
ok('empty untouched')                                { PyResolve.winpath('') == '' }
ok('non-string coerced safely')                      { PyResolve.winpath(nil) == nil }

# Strict no-op OFF Windows (the mac/linux/CI runtime path).
def PyResolve.windows?; false; end
ok('no-op on non-Windows: /c/… passes through unchanged') { PyResolve.winpath('/c/Users/x/f.twbx') == '/c/Users/x/f.twbx' }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
