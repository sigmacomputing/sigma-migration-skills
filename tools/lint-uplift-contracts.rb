#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Guard two durable uplift contracts:
#   1. Generated converter coverage matrices match their JSON catalogs.
#   2. Existing refs/open-items.md tables contain actionable, evidenced items.
#
# Open-items files remain opt-in. Once present, every Markdown table in the file
# must have ID, status, evidence, and detail (or description) columns.

require 'open3'

root_override = ENV['UPLIFT_CONTRACTS_ROOT']
ROOT = root_override ? File.expand_path(root_override) : File.expand_path('..', __dir__)
Dir.chdir(ROOT)

VALID_STATUSES = %w[open blocked resolved accepted not-applicable].freeze
PLACEHOLDER_EVIDENCE = %w[- tbd].freeze

def converter_skill_dirs
  Dir.glob('plugins/*/skills/*-to-sigma').select { |path| File.directory?(path) }.sort
end

def generated?(path)
  File.file?(path) && File.read(path).include?('GENERATED')
end

def source_name(skill_dir)
  File.basename(skill_dir).sub(/-to-sigma\z/, '')
end

def generator_from_marker(matrix_path)
  return nil unless File.file?(matrix_path)

  File.read(matrix_path)[%r{python3\s+(scripts/[A-Za-z0-9_.-]+\.py)}, 1]
end

def skill_arg_from_marker(matrix_path, fallback)
  return fallback unless File.file?(matrix_path)

  File.read(matrix_path)[/--skill\s+([A-Za-z0-9_-]+)/, 1] || fallback
end

def split_markdown_row(line)
  body = line.strip
  body = body[1..] if body.start_with?('|')
  body = body[0...-1] if body.end_with?('|') && !body.end_with?('\|')
  body.split(/(?<!\\)\|/, -1).map { |cell| cell.gsub('\|', '|').strip }
end

def separator_row?(cells)
  !cells.empty? && cells.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
end

def normalized_header(cell)
  cell.downcase.gsub(/[`*_]/, '').strip.gsub(/\s+/, ' ')
end

def normalized_value(cell)
  cell.strip.gsub(/\A[`*_~]+|[`*_~]+\z/, '').strip
end

failures = []
coverage_count = 0

converter_skill_dirs.each do |skill_dir|
  catalogs = Dir.glob("#{skill_dir}/refs/catalogs/*.json")
  generic_generator = "#{skill_dir}/scripts/gen-coverage-matrix.py"
  next if catalogs.empty? || !File.file?(generic_generator)

  skill = source_name(skill_dir)
  inferred_matrix = "#{skill_dir}/refs/#{skill}-coverage.md"
  generated_matrices = Dir.glob("#{skill_dir}/refs/*-coverage.md").select { |path| generated?(path) }
  matrices = ([inferred_matrix] + generated_matrices).uniq.sort

  matrices.each do |matrix_path|
    matrix_rel = matrix_path.delete_prefix("#{skill_dir}/")
    unless File.file?(matrix_path)
      failures << "#{matrix_path}: [coverage-missing] expected generated matrix inferred from #{File.basename(skill_dir)}"
      next
    end

    generator_rel = generator_from_marker(matrix_path) || 'scripts/gen-coverage-matrix.py'
    generator_path = "#{skill_dir}/#{generator_rel}"
    unless File.file?(generator_path)
      failures << "#{matrix_path}: [coverage-generator-missing] #{generator_rel} named by GENERATED matrix does not exist"
      next
    end

    matrix_skill = skill_arg_from_marker(matrix_path, skill)
    stdout, stderr, status = Open3.capture3(
      'python3', generator_rel,
      '--catalogs', 'refs/catalogs',
      '--skill', matrix_skill,
      '--out', matrix_rel,
      '--check',
      chdir: skill_dir
    )
    coverage_count += 1
    next if status.success?

    detail = [stderr, stdout].join(' ').strip.gsub(/\s+/, ' ')
    detail = "generator exited #{status.exitstatus}" if detail.empty?
    failures << "#{matrix_path}: [coverage-stale] #{detail}"
  rescue Errno::ENOENT => e
    failures << "#{matrix_path}: [coverage-check-error] #{e.message}"
  end
end

open_items_count = 0
Dir.glob('plugins/*/skills/*/refs/open-items.md').sort.each do |path|
  open_items_count += 1
  lines = File.readlines(path, chomp: true)
  index = 0

  while index < lines.length - 1
    headers = split_markdown_row(lines[index])
    separators = split_markdown_row(lines[index + 1])
    unless headers.length == separators.length && separator_row?(separators)
      index += 1
      next
    end

    normalized = headers.map { |header| normalized_header(header) }
    id_index = normalized.index('id')
    status_index = normalized.index('status')
    evidence_index = normalized.index('evidence')
    detail_index = normalized.index do |header|
      header.match?(/\A(?:detail|description)(?:\s*\/\s*(?:detail|description))?\z/)
    end

    required = {
      'ID' => id_index,
      'status' => status_index,
      'evidence' => evidence_index,
      'detail/description' => detail_index
    }
    missing = required.select { |_name, column_index| column_index.nil? }.keys
    unless missing.empty?
      failures << "#{path}:#{index + 1}: [open-items-columns] table missing #{missing.join(', ')} column(s)"
    end

    row_index = index + 2
    while row_index < lines.length && lines[row_index].include?('|')
      cells = split_markdown_row(lines[row_index])
      break if cells.empty?

      unless missing.empty?
        row_index += 1
        next
      end

      value = lambda do |column_index|
        normalized_value(cells[column_index] || '')
      end
      id = value.call(id_index)
      status = value.call(status_index).downcase
      evidence = value.call(evidence_index)
      detail = value.call(detail_index)
      line_number = row_index + 1

      failures << "#{path}:#{line_number}: [open-items-id] ID must be non-empty" if id.empty?
      unless VALID_STATUSES.include?(status)
        failures << "#{path}:#{line_number}: [open-items-status] status '#{status}' must be one of #{VALID_STATUSES.join('|')}"
      end
      if evidence.empty? || PLACEHOLDER_EVIDENCE.include?(evidence.downcase)
        failures << "#{path}:#{line_number}: [open-items-evidence] evidence must be non-empty and cannot be '-' or TBD"
      end
      if detail.empty?
        failures << "#{path}:#{line_number}: [open-items-detail] detail/description must be non-empty"
      end

      row_index += 1
    end
    index = row_index
  end
end

if failures.empty?
  puts "OK: uplift contracts clean (#{coverage_count} coverage matrices, #{open_items_count} open-items files)."
  exit 0
end

warn 'UPLIFT CONTRACT LINT FAILED:'
failures.each { |failure| warn "  FAIL  #{failure}" }
warn
warn "#{failures.length} uplift contract violation(s)."
exit 1
