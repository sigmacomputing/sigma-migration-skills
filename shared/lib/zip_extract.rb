# frozen_string_literal: true
#
# zip_extract.rb — dependency-free ZIP reader for .twbx (and other zip) members.
#
# Why: reading a .twbx (a ZIP of the inner .twb + embedded .hyper extract) via the
# `rubyzip` gem crashes on stock RubyInstaller with "cannot load such file -- zip"
# (field-caught), and shelling to `unzip`/python adds interpreter + PATH footguns.
# Ruby ships `zlib` in every MRI build, so this parses the ZIP central directory and
# inflates members with Zlib alone — no gems, no external binaries, no Python.
#
# It reads ONE named member at a time (entries → read), so discovery can inflate the
# small inner .twb and derive the .hyper presence from the NAME list WITHOUT ever
# inflating the multi-GB .hyper into a Ruby String. ZIP64-aware (extract-backed
# .twbx with a >4GB .hyper or >65535 members is written as ZIP64).
require 'zlib'

module ZipExtract
  module_function

  EOCD_SIG    = "PK\x05\x06".b
  EOCD64_SIG  = "PK\x06\x06".b
  LOC64_SIG   = "PK\x06\x07".b
  CEN_SIG     = "PK\x01\x02".b
  U32_MAX     = 0xFFFFFFFF
  U16_MAX     = 0xFFFF

  # All member names (central-directory walk; no inflation). ZIP64-aware.
  def entries(path)
    central(File.binread(path)).map { |e| e[:name] }
  end

  # Inflate/copy exactly ONE member by name; nil if absent.
  def read(path, name)
    buf = File.binread(path)
    e = central(buf).find { |x| x[:name] == name }
    e && member_bytes(buf, e)
  end

  # Extract every member under dest (skips directory entries). Convenience for
  # callers that genuinely need the whole tree; prefer read() for a single member.
  def extract_all(path, dest)
    require 'fileutils'
    buf = File.binread(path)
    central(buf).each do |e|
      next if e[:name].end_with?('/')
      out = File.join(dest, e[:name])
      FileUtils.mkdir_p(File.dirname(out))
      File.binwrite(out, member_bytes(buf, e))
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Locate the End Of Central Directory record (scan back over any trailing comment).
  def eocd_index(buf)
    i = buf.rindex(EOCD_SIG) or raise "not a zip (no EOCD): truncated or wrong file"
    i
  end

  # Return [cd_offset, total_entries], resolving ZIP64 when the classic fields are
  # saturated (0xFFFFFFFF / 0xFFFF).
  def cd_locate(buf)
    e = eocd_index(buf)
    total     = buf[e + 10, 2].unpack1('v')
    cd_offset = buf[e + 16, 4].unpack1('V')
    return [cd_offset, total] unless cd_offset == U32_MAX || total == U16_MAX
    # ZIP64: the locator (PK\x06\x07) sits 20 bytes before the classic EOCD.
    loc = buf.rindex(LOC64_SIG, e) or raise 'zip64 EOCD locator missing'
    z64 = buf[loc + 8, 8].unpack1('Q<')            # offset of the ZIP64 EOCD record
    raise 'zip64 EOCD record missing' unless buf[z64, 4] == EOCD64_SIG
    [buf[z64 + 48, 8].unpack1('Q<'), buf[z64 + 32, 8].unpack1('Q<')]  # cd_offset, total
  end

  # Walk the central directory → [{name, method, csize, lho}, ...].
  def central(buf)
    cd_offset, total = cd_locate(buf)
    out = []
    p = cd_offset
    total.times do
      raise 'corrupt central directory' unless buf[p, 4] == CEN_SIG
      method   = buf[p + 10, 2].unpack1('v')
      csize    = buf[p + 20, 4].unpack1('V')
      nlen     = buf[p + 28, 2].unpack1('v')
      elen     = buf[p + 30, 2].unpack1('v')
      clen     = buf[p + 32, 2].unpack1('v')
      lho      = buf[p + 42, 4].unpack1('V')
      name     = buf[p + 46, nlen]
      extra    = buf[p + 46 + nlen, elen]
      if csize == U32_MAX || lho == U32_MAX
        usize32 = buf[p + 24, 4].unpack1('V')
        csize, lho = zip64_extra(extra, usize32, csize, lho)
      end
      out << { name: name, method: method, csize: csize, lho: lho }
      p += 46 + nlen + elen + clen
    end
    out
  end

  # Parse the 0x0001 ZIP64 extra field. Values appear IN ORDER only for the fields
  # whose classic slot was saturated: uncompressed, compressed, local-header-offset,
  # disk. Returns the resolved [csize, lho].
  def zip64_extra(extra, usize32, csize, lho)
    i = 0
    while i + 4 <= extra.bytesize
      id  = extra[i, 2].unpack1('v')
      len = extra[i + 2, 2].unpack1('v')
      if id == 0x0001
        body = extra[i + 4, len]
        j = 0
        j += 8 if usize32 == U32_MAX                       # skip uncompressed size
        if csize == U32_MAX then csize = body[j, 8].unpack1('Q<'); j += 8 end
        if lho   == U32_MAX then lho   = body[j, 8].unpack1('Q<'); j += 8 end
        break
      end
      i += 4 + len
    end
    [csize, lho]
  end

  # Bytes of one member: re-derive the data start from the LOCAL header (its
  # name/extra lengths can differ from the central copy), then inflate (method 8)
  # or copy (method 0).
  def member_bytes(buf, e)
    lho = e[:lho]
    raise "bad local header @#{lho}" unless buf[lho, 4] == "PK\x03\x04".b
    lnlen = buf[lho + 26, 2].unpack1('v')
    lelen = buf[lho + 28, 2].unpack1('v')
    data  = buf[lho + 30 + lnlen + lelen, e[:csize]]
    case e[:method]
    when 0 then data                                    # stored
    when 8 then Zlib::Inflate.new(-Zlib::MAX_WBITS).inflate(data)  # raw deflate
    else raise "unsupported zip compression method #{e[:method]}"
    end
  end
end
