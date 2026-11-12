# frozen_string_literal: true

# Rerun cache for migrate-powerbi.rb Phase 0/1 (extraction).
#
# WHY. Extracting a large .pbix (pbixray over the VertiPaq model + the report layout)
# costs 60-120 s, and a migration of a big file is a loop of orchestrator reruns: fix
# something, rerun, hit the next gate. Nothing about the extraction changes between
# those reruns, so it is paid again every time.
#
# HOW. Right after a completed extraction the orchestrator records a FINGERPRINT of the
# inputs in <WORK>/run-provenance.json ("extractFingerprint"): a content digest of the
# --pbix (or --tmsl and --pbir), the --name and warehouse dialect the model extraction bakes into model.bim, the pbixray version, and
# a digest of the extractor scripts AND the catalogs they load (an upgraded extractor must
# never be served stale output). On the next run the extraction is skipped when
#   * --reuse-extract is given and the extracted files are on disk, or
#   * the recorded fingerprint equals the current one and the extracted files are on disk,
# and --no-reuse-extract always extracts. A fingerprint is only recorded after the
# extraction finished, so an interrupted run never leaves a cache behind.
#
# Large inputs: files over SAMPLE_ABOVE bytes are digested from size + mtime + the first and
# last SAMPLE_BYTES (a full read of a multi-GB .pbix would eat the saving).
#
# Ruby 2.6 floor: no filter_map / tally / except / endless defs.
require 'json'
require 'digest'
require 'time'

module PbiExtractCache
  module_function

  KEY = 'extractFingerprint'
  SAMPLE_ABOVE = 512 * 1024 * 1024
  SAMPLE_BYTES = 4 * 1024 * 1024
  # The parts of a fingerprint that decide equality (the rest is bookkeeping).
  IDENTITY = %w[route inputs name dialect pbixray extractor].freeze
  # Python files the extraction runs besides the three entry scripts.
  EXTRACTOR_SCRIPTS = %w[extract-model-pbix.py extract-report-classic.py extract-pbir.py].freeze
  # Data files the extractors load (lib/pbi_viz_kind.py -> sigma_kind / role_class / approximate in
  # signals.json). Relative to the skill dir (the parent of scripts/). A catalog-only edit must
  # invalidate the cache just like a script edit.
  EXTRACTOR_DATA_FILES = %w[refs/catalogs/viz-kind.json refs/catalogs/custom-visual.json].freeze

  def file_digest(path)
    return nil unless path && File.file?(path)

    size = File.size(path)
    return "sha256:#{Digest::SHA256.file(path).hexdigest}" if size <= SAMPLE_ABOVE

    sha = Digest::SHA256.new
    File.open(path, 'rb') do |f|
      sha << f.read(SAMPLE_BYTES).to_s
      f.seek([size - SAMPLE_BYTES, 0].max)
      sha << f.read(SAMPLE_BYTES).to_s
    end
    "sampled-sha256:#{sha.hexdigest}:#{size}:#{File.mtime(path).to_i}"
  end

  # Digest of the extractor sources under scripts_dir (entry scripts + scripts/lib/*.py) and of the
  # data files they load (EXTRACTOR_DATA_FILES under the skill dir = scripts_dir/..).
  def extractor_digest(scripts_dir)
    files = EXTRACTOR_SCRIPTS.map { |f| File.join(scripts_dir, f) } +
            Dir[File.join(scripts_dir, 'lib', '*.py')].sort
    sha = Digest::SHA256.new
    files.each do |f|
      sha << File.basename(f) << "\0" << (File.file?(f) ? File.binread(f) : '') << "\0"
    end
    EXTRACTOR_DATA_FILES.each do |rel|
      f = File.join(scripts_dir, '..', rel)
      sha << 'data/' << rel << "\0" << (File.file?(f) ? File.binread(f) : '') << "\0"
    end
    "sha256:#{sha.hexdigest}"
  end

  # Installed pbixray version as seen by the configured python (the VertiPaq decode it ships decides
  # model.bim). nil when it cannot be read cheaply (no python, not installed): then it is skipped.
  def pbixray_version(py_argv)
    require 'open3'
    code = 'import importlib.metadata as m; print(m.version("pbixray"))'
    # Runs the configured Python with a fixed -c literal that reads pbixray's version.
    # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec
    out, st = Open3.capture2(*py_argv, '-c', code, err: File::NULL)
    v = out.to_s.strip
    st.success? && !v.empty? ? v : nil
  rescue StandardError
    nil
  end

  # route: 'pbix' (fully local) or 'tmsl-pbir' (Fabric extract / bundle).
  def fingerprint(pbix:, tmsl:, pbir:, name:, scripts_dir:, dialect: nil, pbixray: nil)
    if pbix
      route = 'pbix'
      inputs = { 'pbix' => file_digest(pbix) }
    else
      route = 'tmsl-pbir'
      inputs = { 'tmsl' => file_digest(tmsl), 'pbir' => file_digest(pbir) }
    end
    { 'route' => route, 'inputs' => inputs,
      # model.bim carries --name for the pbix route only
      'name' => (route == 'pbix' ? name.to_s : ''),
      # Enter-data SQL in model.bim is dialect-specific, and so is the pbixray decode (pbix route only)
      'dialect' => (route == 'pbix' ? dialect.to_s : ''),
      'pbixray' => (route == 'pbix' ? pbixray.to_s : ''),
      'extractor' => extractor_digest(scripts_dir) }
  end

  def same?(recorded, current)
    return false unless recorded.is_a?(Hash) && current.is_a?(Hash)

    IDENTITY.all? { |k| recorded[k] == current[k] } &&
      recorded['inputs'].is_a?(Hash) && recorded['inputs'].values.none?(&:nil?)
  end

  # Files Phase 0/1 produce that the rest of the run reads from <WORK>.
  def required_files(work, route)
    names = %w[signals.json]
    names += %w[model.bim report-layout.json] if route == 'pbix'
    names.map { |n| File.join(work, n) }
  end

  def files_present?(work, route)
    required_files(work, route).all? { |f| File.file?(f) && File.size(f).positive? }
  end

  def provenance_path(work)
    File.join(work, 'run-provenance.json')
  end

  def recorded(work)
    prov = JSON.parse(File.read(provenance_path(work)))
    prov.is_a?(Hash) ? prov[KEY] : nil
  rescue StandardError
    nil
  end

  # Decide whether to skip extraction. Returns
  #   { 'reuse' => bool, 'mode' => 'forced'|'fingerprint'|nil, 'reason' => String,
  #     'saved_seconds' => Float|nil }
  def decide(work, current, forced: false, disabled: false)
    return { 'reuse' => false, 'mode' => nil, 'reason' => '--no-reuse-extract given' } if disabled

    route = current['route']
    prior = recorded(work)
    present = files_present?(work, route)
    saved = prior.is_a?(Hash) ? prior['extractSeconds'] : nil
    if forced
      unless present
        missing = required_files(work, route).reject { |f| File.file?(f) && File.size(f).positive? }
                                             .map { |f| File.basename(f) }
        return { 'reuse' => false, 'mode' => nil,
                 'reason' => "--reuse-extract given but #{missing.join(', ')} not in #{work}; extracting" }
      end
      why = if prior.nil? then 'no input fingerprint recorded'
            elsif same?(prior, current) then 'input fingerprint matches'
            else 'input fingerprint DIFFERS from the recorded one (reusing anyway: --reuse-extract)'
            end
      return { 'reuse' => true, 'mode' => 'forced', 'reason' => "--reuse-extract (#{why})", 'saved_seconds' => saved }
    end
    return { 'reuse' => false, 'mode' => nil, 'reason' => 'no recorded input fingerprint' } if prior.nil?
    return { 'reuse' => false, 'mode' => nil, 'reason' => 'inputs or extractor changed since the recorded extraction' } unless same?(prior, current)
    return { 'reuse' => false, 'mode' => nil, 'reason' => 'extracted files missing from the work dir' } unless present

    { 'reuse' => true, 'mode' => 'fingerprint', 'reason' => 'input fingerprint matches the recorded extraction',
      'saved_seconds' => saved }
  end

  # Merge the fingerprint (+ extraction bookkeeping) into run-provenance.json.
  def record(work, fingerprint, extract_seconds)
    path = provenance_path(work)
    prov = (JSON.parse(File.read(path)) rescue {})
    prov = {} unless prov.is_a?(Hash)
    prov[KEY] = fingerprint.merge('extractSeconds' => extract_seconds,
                                  'recordedAt' => Time.now.utc.iso8601)
    File.write(path, JSON.pretty_generate(prov))
    prov[KEY]
  end

  # Drop a stale fingerprint (an extraction is about to run and has not finished).
  def clear(work)
    path = provenance_path(work)
    prov = (JSON.parse(File.read(path)) rescue nil)
    return unless prov.is_a?(Hash) && prov.key?(KEY)

    prov.delete(KEY)
    File.write(path, JSON.pretty_generate(prov))
  end

  # The note appended to the PHASE TIMINGS line when the cache was used.
  def timings_note(decision, elapsed_seconds)
    saved = decision['saved_seconds']
    est = saved && saved.to_f >= 1 ? ", saved ~#{[saved.to_f - elapsed_seconds.to_f, 0].max.round}s of the original #{saved.round}s extraction" : ''
    "extract-cache: reused Phase 0/1 extraction (#{decision['mode']}#{est})"
  end
end
