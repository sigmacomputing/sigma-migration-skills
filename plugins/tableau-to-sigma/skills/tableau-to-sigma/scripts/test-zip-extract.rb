#!/usr/bin/env ruby
# frozen_string_literal: true
# Hermetic offline test (bead tt3z.16): ZipExtract reads .twbx members with stdlib
# Zlib only — no `zip`/`unzip`/python. Builds a classic ZIP in-Ruby (STORE + DEFLATE
# + a directory entry + a UTF-8 name) and round-trips it, then unit-tests the ZIP64
# central-field resolution (the branch that guards extract-backed .twbx > 4 GB).
require 'zlib'
require_relative 'lib/zip_extract'

$fail = 0
def ok(d); r = yield; puts "#{r ? '  ok  ' : ' FAIL '} #{d}"; $fail += 1 unless r; end

# Assemble a minimal, spec-correct classic ZIP from [[name, bytes, method], ...]
# (method 0 = store, 8 = raw deflate). Inverse of ZipExtract's reader.
def build_zip(members)
  locals = +''.b
  central = +''.b
  offsets = []
  members.each do |name, data, method|
    data = data.b
    stored = method == 8 ? Zlib::Deflate.deflate(data, Zlib::DEFAULT_COMPRESSION).then { |z| z } : data
    stored = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).deflate(data, Zlib::FINISH) if method == 8
    crc = Zlib.crc32(data)
    offsets << locals.bytesize
    n = name.b
    locals << ["PK\x03\x04".b, 20, 0, method, 0, 0, crc, stored.bytesize, data.bytesize, n.bytesize, 0].pack('a4vvvvvVVVvv') << n << stored
  end
  cd_offset = locals.bytesize
  members.each_with_index do |(name, data, method), i|
    data = data.b
    stored_size = method == 8 ? Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).deflate(data, Zlib::FINISH).bytesize : data.bytesize
    crc = Zlib.crc32(data)
    n = name.b
    central << ["PK\x01\x02".b, 20, 20, 0, method, 0, 0, crc, stored_size, data.bytesize, n.bytesize, 0, 0, 0, 0, 0, offsets[i]].pack('a4vvvvvvVVVvvvvvVV') << n
  end
  eocd = ["PK\x05\x06".b, 0, 0, members.size, members.size, central.bytesize, cd_offset, 0].pack('a4vvvvVVv')
  locals + central + eocd
end

require 'tmpdir'
Dir.mktmpdir do |d|
  twb = %(<workbook>— em-dash é unicode — dateadd(...) &lt;= x</workbook>) # non-ASCII → UTF-8 exercise
  hyper = ("\x89HYPER\x00".b + ("\xDE\xAD\xBE\xEF".b * 2000))
  zip = build_zip([['wb.twb', twb, 8], ['Data/x.hyper', hyper, 0], ['Data/', ''.b, 0]])
  path = File.join(d, 'a.twbx'); File.binwrite(path, zip)

  names = ZipExtract.entries(path)
  ok('entries lists every member incl. the dir entry') { names.sort == ['Data/', 'Data/x.hyper', 'wb.twb'] }
  got = ZipExtract.read(path, 'wb.twb')
  ok('DEFLATE member round-trips bytes exactly') { got.b == twb.b }
  ok('inflated .twb is valid UTF-8') { got.force_encoding('UTF-8').valid_encoding? }
  ok('STORE .hyper round-trips bytes exactly') { ZipExtract.read(path, 'Data/x.hyper').b == hyper }
  ok('.hyper presence derivable from names (no inflation)') { names.any? { |n| n.downcase.end_with?('.hyper') } }
  ok('missing member → nil') { ZipExtract.read(path, 'nope').nil? }
end

# ZIP64 central-field resolution: classic csize/lho are 0xFFFFFFFF sentinels; real
# 64-bit values live in the 0x0001 extra (order: uncompressed?, compressed?, lho?).
# uncompressed is NOT saturated here (usize32 != FFFFFFFF) so it is absent from the extra.
body = [0x123456789, 0x2ABCDEF01].pack('Q<Q<')            # csize, lho
extra = [0x0001, body.bytesize].pack('vv') + body
csize, lho = ZipExtract.zip64_extra(extra, 100, 0xFFFFFFFF, 0xFFFFFFFF)
ok('zip64_extra resolves 64-bit csize') { csize == 0x123456789 }
ok('zip64_extra resolves 64-bit local-header offset') { lho == 0x2ABCDEF01 }
# When only lho is saturated, the extra carries only the lho value (compressed absent).
body2 = [0x3FFFFFFFF].pack('Q<')
extra2 = [0x0001, body2.bytesize].pack('vv') + body2
csize2, lho2 = ZipExtract.zip64_extra(extra2, 100, 4242, 0xFFFFFFFF)
ok('zip64_extra leaves a non-saturated csize untouched') { csize2 == 4242 }
ok('zip64_extra resolves lho when it is the only saturated field') { lho2 == 0x3FFFFFFFF }

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
