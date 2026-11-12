# frozen_string_literal: true

require 'json'
require_relative 'twb_xml'

# ds_publication.rb — is a Tableau datasource PUBLISHED (a Tableau Server data
# source VDS can query by LUID) or not? Positive evidence only.
#
# vds-oracle reports `skipped-no-luid` whenever no LUID resolved — for an
# embedded datasource (nothing to resolve, ever) AND for a published one whose
# lookup did not run (--offline, missing creds, a failed name lookup, no
# pds.json). verify-ground-truth may substitute view-csv anchors for the vds
# oracle only in the first case, so it asks here:
#   :published   — the .twb datasource carries a <connection class='sqlproxy'>
#                  (a published data source), or pds.json names it;
#   :unpublished — the .twb datasource exists and has connections, none sqlproxy
#                  (inline/embedded datasource, incl. one over a virtual
#                  connection: class federated + publishedConnection);
#   :unknown     — no .twb, or the caption cannot be matched to one datasource.
module DsPublication
  module_function

  def norm(s)
    s.to_s.strip.downcase
  end

  def twb_path(workdir)
    pref = File.join(workdir.to_s, 'workbook-content.twb')
    return pref if File.file?(pref)
    Dir.glob(File.join(workdir.to_s, '*.twb')).min
  end

  def pds_captions(workdir)
    doc = (JSON.parse(File.read(File.join(workdir.to_s, 'pds.json'), encoding: 'UTF-8')) rescue nil)
    Array(doc).flat_map { |d| d.is_a?(Hash) && !d['pdsLuid'].to_s.empty? ? [d['caption'], d['pdsName']] : [] }
              .map { |c| norm(c) }.reject(&:empty?)
  end

  # caption => [connection classes] for every top-level datasource that has a
  # <connection> (worksheet-level <datasource> references carry none).
  def datasources(workdir)
    path = twb_path(workdir)
    return {} unless path
    xml = TwbXml.parse(File.read(path, encoding: 'UTF-8'))
    out = {}
    xml.elements.each('/workbook/datasources/datasource') do |ds|
      next if ds.attributes['name'].to_s == 'Parameters'
      classes = []
      ds.elements.each('.//connection') { |c| classes << c.attributes['class'].to_s }
      next if classes.empty?
      key = norm(ds.attributes['caption'] || ds.attributes['name'])
      out[key] = (out[key] || []) + classes
    end
    out
  rescue StandardError
    {}
  end

  # caption may be empty (single-datasource workbooks): the lone datasource.
  def status(workdir, caption)
    return :published if !norm(caption).empty? && pds_captions(workdir).include?(norm(caption))
    dss = datasources(workdir)
    classes = if norm(caption).empty?
                dss.size == 1 ? dss.values.first : nil
              else
                dss[norm(caption)]
              end
    return :unknown if classes.nil? || classes.empty?
    classes.include?('sqlproxy') ? :published : :unpublished
  end
end
