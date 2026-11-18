#!/usr/bin/env ruby
# frozen_string_literal: true
# Live discovery of one Lightdash dashboard: its charts and the compiled explores they use.
# UNVALIDATED against a real instance (coded from the documented REST API; tests use a fake
# transport). Needs LIGHTDASH_URL + LIGHTDASH_API_KEY.
#
#   ruby scripts/lightdash-discover.rb --probe
#   ruby scripts/lightdash-discover.rb --project <uuid> --dashboard <slug|uuid|name> --out-dir discovery
#
# Calls (all GET): /api/v1/org (probe), /api/v1/projects/{p}/dashboards/code,
# /api/v1/projects/{p}/charts/code, /api/v1/projects/{p}/explores/{exploreId}.
# Writes, in the exact `lightdash download` layout the offline converter reads:
#   <out>/lightdash/dashboards/<slug>.yml   <out>/lightdash/charts/<slug>.yml
#   <out>/explores/<exploreId>.json         (LightdashModel.load_explores reads these)
#   <out>/manifest.json                     {project, dashboard, charts, explores, warnings, ...}

require 'optparse'
require 'json'
require 'yaml'
require 'fileutils'
require_relative 'lib/lightdash_rest'

module LightdashDiscover
  class Error < StandardError; end

  module_function

  # The /code endpoints are documented as returning the download payload; the envelope key is
  # not pinned down, so accept a bare list or {dashboards|charts: [...]} / {<anything>: [...]}.
  def list_from(results, key)
    return results if results.is_a?(Array)
    return [] unless results.is_a?(Hash)
    v = results[key] || results.values.find { |x| x.is_a?(Array) }
    v.is_a?(Array) ? v : []
  end

  def find_dashboard(dashboards, ref)
    ref = ref.to_s
    dashboards.find { |d| d['slug'].to_s == ref } ||
      dashboards.find { |d| d['uuid'].to_s == ref || d['dashboardUuid'].to_s == ref } ||
      dashboards.find { |d| d['name'].to_s.casecmp?(ref) }
  end

  def chart_slugs(dashboard)
    Array(dashboard['tiles']).map do |t|
      next unless t.is_a?(Hash) && t['type'].to_s == 'saved_chart'
      (t['properties'] || {})['chartSlug']
    end.compact.map(&:to_s).uniq
  end

  def explore_ids(charts)
    charts.map { |c| (c['metricQuery'] || {})['exploreName'] || c['tableName'] }.compact.map(&:to_s).reject(&:empty?).uniq
  end

  def safe_name(s)
    n = s.to_s.gsub(/[^A-Za-z0-9_.-]+/, '-').sub(/\A\.+/, '')
    n.empty? ? 'unnamed' : n
  end

  def write_yaml(path, hash)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump(JSON.parse(JSON.generate(hash))))
  end

  # Returns the manifest hash. Raises Error when the dashboard cannot be found.
  def discover(client, project:, dashboard:, out_dir:)
    base = "/api/v1/projects/#{project}"
    warnings = []
    dashboards = list_from(client.get("#{base}/dashboards/code"), 'dashboards')
    dash = find_dashboard(dashboards, dashboard)
    raise Error, "dashboard #{dashboard.inspect} not found in project #{project} (#{dashboards.length} dashboards listed)" unless dash
    slug = safe_name(dash['slug'] || dashboard)
    wanted = chart_slugs(dash)
    all_charts = list_from(client.get("#{base}/charts/code"), 'charts')
    by_slug = all_charts.each_with_object({}) { |c, h| h[c['slug'].to_s] = c if c.is_a?(Hash) }
    charts = wanted.map { |s| by_slug[s] }.compact
    (wanted - by_slug.keys).each { |s| warnings << "chart #{s} is referenced by the dashboard but was not returned by charts/code" }

    write_yaml(File.join(out_dir, 'lightdash', 'dashboards', "#{slug}.yml"), dash)
    charts.each { |c| write_yaml(File.join(out_dir, 'lightdash', 'charts', "#{safe_name(c['slug'])}.yml"), c) }

    explores = explore_ids(charts)
    explores.each do |id|
      explore = client.get("#{base}/explores/#{id}")
      unless explore.is_a?(Hash) && explore['tables'].is_a?(Hash)
        warnings << "explore #{id}: response has no `tables`; the offline model loader will skip it"
      end
      FileUtils.mkdir_p(File.join(out_dir, 'explores'))
      File.write(File.join(out_dir, 'explores', "#{safe_name(id)}.json"), JSON.pretty_generate(explore) + "\n")
    end

    manifest = { 'project' => project, 'dashboard' => slug, 'dashboard_name' => dash['name'],
                 'charts' => charts.map { |c| c['slug'] }, 'explores' => explores,
                 'out_dir' => File.expand_path(out_dir), 'warnings' => warnings }
    FileUtils.mkdir_p(out_dir)
    File.write(File.join(out_dir, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
    manifest
  end

  def probe(client)
    org = client.get('/api/v1/org')
    name = org.is_a?(Hash) ? org['name'] : nil
    return "Lightdash probe OK: organization #{name.inspect}" if name
    projects = client.get('/api/v1/org/projects')
    "Lightdash probe OK: #{projects.is_a?(Array) ? projects.length : '?'} project(s)"
  rescue LightdashRest::Error => e
    raise Error, "probe failed: #{e.message}"
  end

  def run(argv, client: nil)
    opts = { out_dir: File.expand_path('../discovery', __dir__) }
    OptionParser.new do |o|
      o.on('--probe') { opts[:probe] = true }
      o.on('--project UUID') { |v| opts[:project] = v }
      o.on('--dashboard REF') { |v| opts[:dashboard] = v }
      o.on('--out-dir DIR') { |v| opts[:out_dir] = v }
    end.parse!(argv)
    client ||= LightdashRest::Client.from_env
    if opts[:probe]
      warn probe(client)
      return 0
    end
    raise Error, 'missing --project' if opts[:project].to_s.empty?
    raise Error, 'missing --dashboard' if opts[:dashboard].to_s.empty?
    m = discover(client, project: opts[:project], dashboard: opts[:dashboard], out_dir: File.expand_path(opts[:out_dir]))
    m['warnings'].each { |w| warn "warning: #{w}" }
    warn "discovered dashboard #{m['dashboard']}: #{m['charts'].length} chart(s), #{m['explores'].length} explore(s) -> #{m['out_dir']}"
    0
  rescue LightdashRest::Error, Error, OptionParser::ParseError => e
    warn "error: #{e.message}"
    1
  end
end

exit(LightdashDiscover.run(ARGV)) if __FILE__ == $PROGRAM_NAME
