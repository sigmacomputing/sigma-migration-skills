# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'blind_grade'

module DomoVisualHandoff
  EXIT_PENDING = 20
  SOURCE_BASENAME = 'source-dashboard.png'
  TARGET_BASENAME = 'sigma-render.png'
  GRADE_BASENAME = 'blind-grade.json'
  REQUEST_BASENAME = 'visual-grade-request.json'
  CHECKLIST_KEYS = BlindGrade::DIMENSION_KEYS

  module_function

  def png?(path)
    File.file?(path.to_s) && File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b
  rescue StandardError
    false
  end

  def stage_source!(source_path, workdir)
    source = File.expand_path(source_path.to_s)
    raise ArgumentError, "source dashboard PNG not found or invalid: #{source}" unless png?(source)

    target = File.join(workdir, SOURCE_BASENAME)
    FileUtils.cp(source, target) unless source == File.expand_path(target)
    target
  end

  SECOND_GRADE_BASENAME = 'blind-grade-2.json'

  def write_request!(workdir:, source_path:, target_path:, rubric_path:, brief_path:,
                     grade_path:, reason: nil, catalog_path: nil)
    request = {
      'schema' => 'domo-visual-grade-request/v1',
      'status' => source_path ? 'awaiting-blind-grade' : 'awaiting-source-dashboard',
      'source_png' => source_path,
      'target_png' => target_path,
      'rubric_path' => rubric_path,
      'brief_path' => brief_path,
      'catalog_path' => catalog_path,
      'second_grade_output_json' => File.join(workdir, SECOND_GRADE_BASENAME),
      'second_grade_note' => 'Only when the first grade scores within 5 of 75 (record-visual-check refuses it ' \
                             "with \"second blind grader required\"): run the SAME brief again in a fresh grader with OUT_JSON=#{SECOND_GRADE_BASENAME}, then rerun the same command.",
      'output_json' => grade_path,
      'resume_command' => 'rerun the same migrate-domo.rb command; it will consume the grade idempotently',
      'reason' => reason
    }.compact
    path = File.join(workdir, REQUEST_BASENAME)
    File.write(path, JSON.pretty_generate(request) + "\n")
    path
  end

  def default_catalog_path
    File.expand_path('../../refs/sigma-platform-differences.json', __dir__)
  end

  # v1 grades never consult the catalog; v2 grades are validated against it
  # (catalog sha + cited ids). A catalog that fails to load is reported as a
  # validation error so the caller treats the grade as unconsumable.
  def validate_grade(grade_path, workdir:, catalog_path: default_catalog_path)
    catalog = BlindGrade.load_catalog(catalog_path)
    res = BlindGrade.load_and_validate(grade_path, workdir: workdir, catalog: catalog['errors'].empty? ? catalog : nil)
    if catalog['errors'].any? && res['doc'] && res['doc']['schema'].to_s == BlindGrade::SCHEMA_V2
      res['errors'] = catalog['errors'].map { |e| "catalog: #{e}" } + res['errors']
    end
    res
  end

  def record_args(validation, workdir:, target_path:, grade_path:, catalog_path: default_catalog_path)
    doc = validation.fetch('doc')
    return record_args_v2(doc, workdir: workdir, target_path: target_path, grade_path: grade_path,
                               catalog_path: catalog_path) if doc['schema'].to_s == BlindGrade::SCHEMA_V2

    checklist = CHECKLIST_KEYS.map do |key|
      "#{key}=#{doc.fetch('dimensions').fetch(key).fetch('verdict')}"
    end.join(',')
    gaps = Array(doc['top_gaps']).map(&:to_s).reject(&:empty?)
    notes = gaps.empty? ? 'Context-free blind visual grade completed.' : gaps.join('; ')
    [
      '--workdir', workdir,
      '--agent-vision', 'true',
      '--verdict', (doc.fetch('verdict') == 'pass' ? 'pass' : 'divergent'),
      '--notes', notes,
      '--screenshot', target_path,
      '--blind-grade', File.expand_path(grade_path, workdir),
      '--checklist', checklist
    ]
  end

  # v2: record-visual-check COMPUTES the verdict and derives the checklist, so
  # neither is passed; there is no --catalog (the shipped catalog is the only
  # one). The second grade rides along ONLY when grade 1 alone is borderline
  # (record-visual-check and gate 8b refuse a second grade otherwise) and it
  # exists on disk.
  def record_args_v2(doc, workdir:, target_path:, grade_path:, catalog_path:)
    gaps = Array(doc['gaps']).map { |g| g.is_a?(Hash) ? g['description'].to_s : '' }.reject(&:empty?)
    notes = gaps.empty? ? 'Context-free blind visual grade completed.' : gaps.join('; ')
    args = [
      '--workdir', workdir,
      '--agent-vision', 'true',
      '--notes', notes,
      '--screenshot', target_path,
      '--blind-grade', File.expand_path(grade_path, workdir)
    ]
    second = File.join(workdir, SECOND_GRADE_BASENAME)
    args += ['--blind-grade-2', second] if File.file?(second) && borderline?(doc, catalog_path)
    args
  end

  # Is this single v2 grade within the borderline band (a second grader owed)?
  def borderline?(doc, catalog_path = default_catalog_path)
    catalog = BlindGrade.load_catalog(catalog_path)
    BlindGrade.faithful([doc], catalog)['needs_second']
  end
end
