# frozen_string_literal: true

# source_png.rb — the source dashboard PNG for a page name.
#
# Discovery saves dashboards/<name, runs of non-word chars → "_">.png
# ("Fulfillment_Performance.png"); the RCF render and export-viewport looked
# for dashboards/<page name>.png ("Fulfillment Performance.png"), found
# nothing, and wrote no source composite (Stress 4: the agent copied the PNGs
# by hand). Resolve the exact name first, then the underscore form, then a
# case-/punctuation-insensitive match; nil when none exists.
module SourcePng
  module_function

  def key(name)
    name.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def path(workdir, name)
    return nil if name.to_s.empty?
    dir = File.join(workdir.to_s, 'dashboards')
    exact = File.join(dir, "#{name}.png")
    return exact if File.file?(exact)
    under = File.join(dir, "#{name.to_s.strip.gsub(/[^\w.-]+/, '_').gsub(/\A_+|_+\z/, '')}.png") # tableau-discover's form
    return under if File.file?(under)
    Dir.glob(File.join(dir, '*.png')).sort.find { |p| key(File.basename(p, '.png')) == key(name) }
  end
end
