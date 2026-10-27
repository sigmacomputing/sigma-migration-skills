# frozen_string_literal: true
# Load an Omni shared-model checkout (git projection or yaml-get dump) and
# optional workbookModel from a dashboard export.
# File names follow Omni's IDE: *.view, *.topic, relationships.yaml, model.yaml.
# Query views (*.query.view) are recorded and skipped by the DM converter.

require 'yaml'

module OmniModel
  module_function

  def load(dir)
    root = File.expand_path(dir)
    abort "model dir not found: #{dir}" unless File.directory?(root)
    model = {
      'root' => root,
      'views' => {},
      'topics' => {},
      'relationships' => [],
      'model' => {},
      'query_views' => []
    }
    Dir.glob(File.join(root, '**', '*')).sort.each do |path|
      next unless File.file?(path)
      rel = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      base = File.basename(path)
      if relationship_file?(base)
        parsed = YAML.safe_load(File.read(path))
        model['relationships'] = Array(parsed)
      elsif model_file?(base)
        model['model'] = YAML.safe_load(File.read(path)) || {}
      elsif query_view_file?(base)
        model['query_views'] << rel
      elsif view_file?(base)
        doc = YAML.safe_load(File.read(path)) || {}
        if doc.is_a?(Hash) && doc['query'].is_a?(Hash) && doc['table_name'].nil?
          model['query_views'] << rel
          next
        end
        name = view_name(path, doc)
        model['views'][name] = doc.merge('_file' => rel, '_name' => name)
      elsif topic_file?(base)
        doc = YAML.safe_load(File.read(path)) || {}
        key = topic_key(base)
        model['topics'][key] = doc.merge('_file' => rel, '_key' => key)
      end
    end
    resolve_view_extends!(model['views'])
    resolve_topic_extends!(model['topics'])
    model
  end

  def relationship_file?(base)
    %w[relationships relationships.yaml relationships.yml].include?(base)
  end

  def model_file?(base)
    %w[model model.yaml model.yml].include?(base)
  end

  def query_view_file?(base)
    base.end_with?('.query.view', '.query.view.yaml', '.query.view.yml')
  end

  def view_file?(base)
    (base.end_with?('.view', '.view.yaml', '.view.yml')) && !query_view_file?(base)
  end

  def topic_file?(base)
    base.end_with?('.topic', '.topic.yaml', '.topic.yml')
  end

  def view_name(path, doc)
    text = File.read(path)
    commented = text[/Reference this view as ([A-Za-z0-9_]+)/, 1]
    return commented if commented
    explicit = doc['view_name'] || doc['name']
    return explicit.to_s if explicit.is_a?(String) && !explicit.empty?
    File.basename(path).sub(/\.view\.(yaml|yml)\z/, '').sub(/\.view\z/, '')
  end

  def topic_key(base)
    base.sub(/\.(yaml|yml)\z/, '').sub(/\.topic\z/, '')
  end

  def resolve_view_extends!(views)
    views.each_value do |view|
      parent_names = Array(view['extends']).map(&:to_s).reject(&:empty?)
      next if parent_names.empty?
      parent_names.each do |pname|
        parent = views[pname]
        next unless parent.is_a?(Hash)
        view['schema'] ||= parent['schema']
        view['table_name'] ||= parent['table_name']
        view['dimensions'] = deep_merge_fields(parent['dimensions'], view['dimensions'])
        view['measures'] = deep_merge_fields(parent['measures'], view['measures'])
      end
    end
  end

  def resolve_topic_extends!(topics)
    topics.each_value do |topic|
      parent_names = Array(topic['extends']).map(&:to_s).reject(&:empty?)
      next if parent_names.empty?
      parent_names.each do |pname|
        parent = topics[pname]
        next unless parent.is_a?(Hash)
        topic['base_view'] ||= parent['base_view']
        topic['label'] ||= parent['label']
        if topic['joins'].nil? && parent['joins'].is_a?(Hash)
          topic['joins'] = Marshal.load(Marshal.dump(parent['joins']))
        end
      end
    end
  end

  def deep_merge_fields(parent_fields, child_fields)
    p_hash = parent_fields.is_a?(Hash) ? parent_fields : {}
    c_hash = child_fields.is_a?(Hash) ? child_fields : {}
    merged = {}
    p_hash.each { |k, v| merged[k] = v.is_a?(Hash) ? v.dup : v }
    c_hash.each do |k, v|
      if merged[k].is_a?(Hash) && v.is_a?(Hash)
        merged[k] = merged[k].merge(v)
      else
        merged[k] = v
      end
    end
    merged
  end

  # Merge Omni dashboard export's `workbookModel` (workbook-layer dimensions,
  # binned dimensions, timeframe variants, and workbook measures) into `model`.
  # Supports both the array-of-views shape (`workbookModel.views`) and the
  # dotted-key hash shape (`workbookModel.dimensions['view.field']`).
  def merge_workbook_model!(model, wb_model)
    return model unless wb_model.is_a?(Hash)
    %w[dimensions measures].each do |section|
      node = wb_model[section]
      next unless node.is_a?(Hash)
      node.each do |qualified_key, spec|
        next unless spec.is_a?(Hash)
        vname, fname = qualified_key.to_s.split('.', 2)
        next if vname.to_s.empty? || fname.to_s.empty?
        target = (model['views'][vname] ||= {
          '_name' => vname,
          'dimensions' => {},
          'measures' => {}
        })
        target[section] ||= {}
        target[section][fname] ||= spec
      end
    end
    Array(wb_model['views']).each do |wb_view|
      next unless wb_view.is_a?(Hash)
      vname = wb_view['name'].to_s
      next if vname.empty?
      target = (model['views'][vname] ||= {
        '_name' => vname,
        'label' => wb_view['label'],
        'dimensions' => {},
        'measures' => {}
      })
      target['dimensions'] ||= {}
      target['measures'] ||= {}
      Array(wb_view['dimensions']).each do |dim|
        next unless dim.is_a?(Hash)
        fname = dim['field_name'].to_s
        next if fname.empty? || fname.include?('[')
        next if target['dimensions'].key?(fname)
        spec = {}
        spec['label'] = dim['label'] if dim['label']
        spec['group_label'] = dim['group_label'] if dim['group_label']
        spec['sql'] = dim['sql'] if dim['sql']
        spec['bin_boundaries'] = dim['bin_boundaries'] if dim['bin_boundaries'].is_a?(Array)
        spec['timeframes'] = dim['time_frames'].map(&:downcase) if dim['time_frames'].is_a?(Array)
        spec['tags'] = dim['tags'] if dim['tags'].is_a?(Array)
        spec['hidden'] = true if dim['hidden'] == true
        spec['ignored'] = true if dim['ignored'] == true
        target['dimensions'][fname] = spec
      end
      Array(wb_view['measures']).each do |meas|
        next unless meas.is_a?(Hash)
        fname = meas['field_name'].to_s
        next if fname.empty?
        next if target['measures'].key?(fname)
        spec = {}
        spec['label'] = meas['label'] if meas['label']
        spec['aggregate_type'] = meas['aggregate_type'].to_s.downcase unless meas['aggregate_type'].to_s.empty?
        sql = meas['original_sql_for_aggregation'] || meas.dig('expr', 'field_name')
        if sql && !sql.to_s.empty?
          sql_str = sql.to_s
          sql_str = "${#{sql_str}}" if sql_str =~ /\A[A-Za-z0-9_]+\.[A-Za-z0-9_]+\z/
          spec['sql'] = sql_str
        elsif meas['display_sql']
          spec['sql'] = meas['display_sql']
        end
        spec['filters'] = meas['filters'] if meas['filters'].is_a?(Hash) && !meas['filters'].empty?
        spec['tags'] = meas['tags'] if meas['tags'].is_a?(Array)
        spec['ignored'] = true if meas['ignored'] == true
        target['measures'][fname] = spec
      end
    end
    model
  end

  def find_topic(model, name)
    return nil if name.nil? || name.empty?
    topics = model['topics']
    return topics[name] if topics[name]
    topics.each_value do |topic|
      label = topic['label'].to_s
      base = topic['base_view'].to_s
      return topic if label.casecmp(name).zero? || base == name || topic['_key'] == name
    end
    nil
  end

  # Topic joins are a nested map. Keys are view names included in the topic.
  def joined_views(topic)
    join_edges(topic).map { |_, child| child }.uniq
  end

  # Returns [parent_view, child_view] pairs in breadth-first order from the
  # topic's base_view down its nested `joins:` (and `added_joins:` minus
  # `removed_joins:`) tree.
  def join_edges(topic)
    return [] unless topic.is_a?(Hash)
    base = topic['base_view'].to_s
    removed = Array(topic['removed_joins']).map(&:to_s)
    tree = {}
    tree.merge!(topic['joins']) if topic['joins'].is_a?(Hash)
    tree.merge!(topic['added_joins']) if topic['added_joins'].is_a?(Hash)
    edges = []
    walk = lambda do |parent, node|
      return unless node.is_a?(Hash)
      node.each do |view, child|
        v = view.to_s
        next if removed.include?(v)
        edges << [parent, v]
        walk.call(v, child)
      end
    end
    walk.call(base, tree)
    edges
  end

  # Evaluates Omni's `fields:` topic parameter in documented order of operations:
  # 1. all_views.*  2. view.*  3. tag:<t>  4. view:tag:<t>  5. view.field
  # A leading `-` excludes matching fields.
  def field_allowed?(topic, view_name, field_name, field_spec = {}, view_spec = {})
    selectors = topic.is_a?(Hash) ? topic['fields'] : nil
    return true unless selectors.is_a?(Array) && !selectors.empty?

    str_selectors = selectors.map { |s| s.to_s.strip }.reject(&:empty?)
    has_positive_root = str_selectors.any? { |s| !s.start_with?('-') && (s == 'all_views.*' || s.end_with?('.*') || s.include?('tag:')) }
    allowed = !has_positive_root
    allowed = true if str_selectors.first&.start_with?('-') && !str_selectors.include?('-all_views.*')

    f_tags = field_spec.is_a?(Hash) ? Array(field_spec['tags']) : Array(field_spec)
    v_tags = view_spec.is_a?(Hash) ? Array(view_spec['tags']) : Array(view_spec)
    field_tags = (f_tags + v_tags).map(&:to_s)

    rank_for = lambda do |raw|
      clean = raw.sub(/\A-/, '')
      if clean == 'all_views.*'
        1
      elsif clean.end_with?('.*')
        2
      elsif clean.start_with?('tag:')
        3
      elsif clean.include?(':tag:')
        4
      else
        5
      end
    end

    matches = lambda do |raw|
      clean = raw.sub(/\A-/, '').strip
      case rank_for.call(raw)
      when 1
        true
      when 2
        clean == "#{view_name}.*"
      when 3
        tag = clean.sub(/\Atag:\s*/, '')
        field_tags.include?(tag)
      when 4
        v, tag = clean.split(':tag:', 2).map(&:strip)
        v == view_name && field_tags.include?(tag)
      when 5
        clean == "#{view_name}.#{field_name}"
      end
    end

    str_selectors.sort_by { |s| rank_for.call(s) }.each do |sel|
      next unless matches.call(sel)
      allowed = !sel.start_with?('-')
    end
    allowed
  end

  # Resolve view or field aliases declared via `aliases:` in Omni YAML.
  def resolve_alias(model, view_name, field_name)
    views = (model && model['views']) || {}
    canonical_view = view_name.to_s
    unless views.key?(canonical_view)
      found = views.find { |_, v| Array(v['aliases']).map(&:to_s).include?(canonical_view) }
      canonical_view = found.first if found
    end
    v = views[canonical_view]
    return [canonical_view, field_name.to_s] unless v.is_a?(Hash)

    fname = field_name.to_s
    %w[dimensions measures].each do |sec|
      section = v[sec]
      next unless section.is_a?(Hash)
      return [canonical_view, fname] if section.key?(fname)
      hit = section.find { |_, spec| spec.is_a?(Hash) && Array(spec['aliases']).map(&:to_s).include?(fname) }
      return [canonical_view, hit.first.to_s] if hit
    end
    [canonical_view, fname]
  end
end
