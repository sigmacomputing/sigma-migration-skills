# frozen_string_literal: true

require 'json'

# Reconcile converter-friendly warehouse references with the target Sigma
# connection. Connections with `friendlyName: false` require physical catalog
# names in warehouse-table formulas and inode ids, while downstream derived
# elements should keep stable human display names.
module WarehouseColumnRefs
  module_function

  def normalize(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def catalog_match(entries, candidates)
    names = entries.map { |entry| entry['name'].to_s }.reject(&:empty?)
    candidates.compact.map(&:to_s).reject(&:empty?).each do |candidate|
      return candidate if names.include?(candidate)
      folded = names.select { |name| name.casecmp(candidate).zero? }
      return folded.first if folded.one?
      normalized = names.select { |name| normalize(name) == normalize(candidate) }
      return normalized.first if normalized.one?
    end
    nil
  end

  def apply!(spec, requester:, lister: nil, friendly_overrides: {})
    connection_modes = {}
    lookups = {}
    aliases = {}
    warehouse_prefixes = {}
    id_map = {}
    unresolved = []
    rewritten = 0
    rekeyed = 0
    reprefixed = 0

    elements = (spec['pages'] || []).flat_map { |page| page['elements'] || [] }
    elements.each do |element|
      source = element['source'] || {}
      next unless source['kind'] == 'warehouse-table'
      connection_id = source['connectionId'].to_s
      path = source['path']
      next if connection_id.empty? || !path.is_a?(Array) || path.empty?

      friendly = if friendly_overrides.key?(connection_id)
                   friendly_overrides[connection_id]
                 else
                   connection_modes.fetch(connection_id) do
                     connection = requester.call(:get, "/v2/connections/#{connection_id}")
                     connection_modes[connection_id] = connection['friendlyName']
                   end
                 end
      raise "connection #{connection_id} did not report friendlyName" unless friendly == true || friendly == false
      connection_modes[connection_id] = friendly
      next if friendly

      element_name = element['name'].to_s
      physical_name = path.last.to_s
      if !element_name.empty? && element_name != physical_name
        existing = aliases[element_name]
        if existing && existing != physical_name
          raise "warehouse element name #{element_name.inspect} maps to both #{existing.inspect} and #{physical_name.inspect}"
        end
        aliases[element_name] = physical_name
      end
      element['name'] = physical_name

      cache_key = [connection_id, path]
      entries = lookups.fetch(cache_key) do
        table = requester.call(:post, "/v2/connection/#{connection_id}/lookup",
                               body: JSON.generate('path' => path))
        inode = table['inodeId']
        raise "#{path.join('.')} did not resolve to a table inode" if table['kind'] != 'table' || inode.to_s.empty?
        columns_path = "/v2/connections/tables/#{inode}/columns"
        raise 'warehouse column lister is required when friendly names are disabled' unless lister
        lookups[cache_key] = lister.call(columns_path)
      end
      ref_map = {}
      entries.each { |entry| ref_map[normalize(entry['name'])] = entry['name'].to_s }
      warehouse_prefixes[physical_name] = true
      warehouse_prefixes[element_name] = true unless element_name.empty?

      (element['columns'] || []).each do |column|
        match = column['formula'].to_s.match(%r{\A\[([^\]/]+)/([^\]/]+)\]\z})
        next unless match
        prefix, leaf = match.captures
        id_leaf = column['id'].to_s.split('/', 2)[1]
        physical = catalog_match(entries, [leaf, column['name'], id_leaf])
        unless physical
          unresolved << "#{path.join('.')}: #{prefix}/#{leaf}" if column['id'].to_s.start_with?('inode-')
          next
        end
        column['name'] = leaf if column['name'].to_s.empty?
        if column['id'].to_s.start_with?('inode-') && id_leaf != physical
          old_id = column['id']
          new_id = "#{old_id.split('/', 2)[0]}/#{physical}"
          id_map[old_id] = new_id
          column['id'] = new_id
          rekeyed += 1
        end
        grounded = "[#{physical_name}/#{physical}]"
        next if column['formula'] == grounded
        column['formula'] = grounded
        rewritten += 1
      end

      ground_element = lambda do |node|
        case node
        when Hash
          if node['formula'].is_a?(String)
            display_name = nil
            node['formula'] = node['formula'].gsub(/\[([^\]\/]+)(\/[^\]]+)\]/) do
              prefix = Regexp.last_match(1)
              original = Regexp.last_match(0)
              parts = Regexp.last_match(2).sub(%r{\A/}, '').split('/')
              next original unless parts.one? && [element_name, physical_name].include?(prefix)
              physical = ref_map[normalize(parts[0])]
              next original unless physical
              display_name ||= parts[0]
              grounded = "[#{physical_name}/#{physical}]"
              rewritten += 1 if grounded != original
              grounded
            end
            node['name'] = display_name if node['name'].to_s.empty? && display_name
          end
          node.each { |key, value| ground_element.call(value) unless key == 'formula' }
        when Array
          node.each { |value| ground_element.call(value) }
        end
      end
      ground_element.call(element)
    end

    unless id_map.empty?
      replace_ids = lambda do |node|
        case node
        when Hash then node.each { |key, value| node[key] = replace_ids.call(value) }
        when Array then node.map! { |value| replace_ids.call(value) }
        when String then id_map.fetch(node, node)
        else node
        end
      end
      replace_ids.call(spec)
    end

    unless aliases.empty? && warehouse_prefixes.empty?
      walk = lambda do |node|
        case node
        when Hash
          if node['formula'].is_a?(String)
            display_name = nil
            node['formula'] = node['formula'].gsub(/\[([^\]\/]+)(\/[^\]]+)\]/) do
              prefix = Regexp.last_match(1)
              parts = Regexp.last_match(2).sub(%r{\A/}, '').split('/')
              replacement = aliases.fetch(prefix, prefix)
              reprefixed += 1 if replacement != prefix
              display_name ||= parts[0] if parts.one? &&
                                             (warehouse_prefixes[prefix] || warehouse_prefixes[replacement])
              "[#{replacement}/#{parts.join('/')}]"
            end
            node['name'] = display_name if node['name'].to_s.empty? && display_name
          end
          node.each { |key, value| walk.call(value) unless key == 'formula' }
        when Array
          node.each { |value| walk.call(value) }
        end
      end
      walk.call(spec)
    end

    unless unresolved.empty?
      raise "warehouse columns not found in the connection catalog: #{unresolved.uniq.join(', ')}"
    end
    { 'rewritten' => rewritten, 'rekeyed' => rekeyed, 'reprefixed' => reprefixed,
      'connectionModes' => connection_modes }
  end
end
