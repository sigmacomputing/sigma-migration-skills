# frozen_string_literal: true

require 'json'

module TableauWarehouseColumnRefs
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

  def apply!(spec, requester:, lister:, drop_unresolved: false)
    modes = {}
    lookups = {}
    aliases = {}
    warehouse_prefixes = {}
    id_map = {}
    unresolved = []
    dropped = []
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

      friendly = modes.fetch(connection_id) do
        modes[connection_id] = requester.call(:get, "/v2/connections/#{connection_id}")['friendlyName']
      end
      raise "connection #{connection_id} did not report friendlyName" unless friendly == true || friendly == false
      next if friendly

      element_name = element['name'].to_s
      physical_name = path.last.to_s
      if !element_name.empty? && element_name != physical_name
        prior = aliases[element_name]
        raise "element #{element_name.inspect} maps to both #{prior.inspect} and #{physical_name.inspect}" if prior && prior != physical_name
        aliases[element_name] = physical_name
      end
      element['name'] = physical_name

      entries = lookups.fetch([connection_id, path]) do
        table = requester.call(:post, "/v2/connection/#{connection_id}/lookup",
                               body: JSON.generate('path' => path))
        inode = table['inodeId']
        raise "#{path.join('.')} did not resolve to a table inode" if table['kind'] != 'table' || inode.to_s.empty?
        lookups[[connection_id, path]] = lister.call("/v2/connections/tables/#{inode}/columns")
      end
      ref_map = entries.each_with_object({}) { |entry, out| out[normalize(entry['name'])] = entry['name'].to_s }
      warehouse_prefixes[physical_name] = true
      warehouse_prefixes[element_name] = true unless element_name.empty?

      drop_ids = []
      (element['columns'] || []).each do |column|
        match = column['formula'].to_s.match(%r{\A\[([^\]/]+)/(.+)\]\z})
        next unless match
        prefix, leaf = match.captures
        id_leaf = column['id'].to_s.split('/', 2)[1]
        physical = catalog_match(entries, [leaf, column['name'], id_leaf])
        unless physical
          if column['id'].to_s.start_with?('inode-') && drop_unresolved
            drop_ids << column['id']
            dropped << "#{path.join('.')}: #{column['name'] || leaf}"
          elsif column['id'].to_s.start_with?('inode-')
            unresolved << "#{path.join('.')}: #{prefix}/#{leaf}"
          end
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
        unless column['formula'] == grounded
          column['formula'] = grounded
          rewritten += 1
        end
      end
      unless drop_ids.empty?
        element['columns'] = (element['columns'] || []).reject { |column| drop_ids.include?(column['id']) }
        element['order'] = (element['order'] || []).reject { |id| drop_ids.include?(id) } if element['order']
        remaining = drop_ids.select { |id| JSON.generate(spec).include?(id.to_s) }
        raise "cannot drop catalog-missing columns still referenced by id: #{remaining.join(', ')}" if remaining.any?
      end

      ground_element = lambda do |node|
        case node
        when Hash
          if node['formula'].is_a?(String)
            display = nil
            node['formula'] = node['formula'].gsub(/\[([^\]\/]+)(\/[^\]]+)\]/) do
              prefix = Regexp.last_match(1)
              original = Regexp.last_match(0)
              parts = Regexp.last_match(2).sub(%r{\A/}, '').split('/')
              next original unless parts.one? && [element_name, physical_name].include?(prefix)
              physical = ref_map[normalize(parts[0])]
              next original unless physical
              display ||= parts[0]
              grounded = "[#{physical_name}/#{physical}]"
              rewritten += 1 if grounded != original
              grounded
            end
            node['name'] = display if node['name'].to_s.empty? && display
          end
          node.each { |key, value| ground_element.call(value) unless key == 'formula' }
        when Array then node.each { |value| ground_element.call(value) }
        end
      end
      ground_element.call(element)
    end

    replace_ids = lambda do |node|
      case node
      when Hash then node.each { |key, value| node[key] = replace_ids.call(value) }
      when Array then node.map! { |value| replace_ids.call(value) }
      when String then id_map.fetch(node, node)
      else node
      end
    end
    replace_ids.call(spec) unless id_map.empty?

    walk = lambda do |node|
      case node
      when Hash
        if node['formula'].is_a?(String)
          display = nil
          node['formula'] = node['formula'].gsub(/\[([^\]\/]+)(\/[^\]]+)\]/) do
            prefix = Regexp.last_match(1)
            parts = Regexp.last_match(2).sub(%r{\A/}, '').split('/')
            replacement = aliases.fetch(prefix, prefix)
            reprefixed += 1 if replacement != prefix
            display ||= parts[0] if parts.one? && (warehouse_prefixes[prefix] || warehouse_prefixes[replacement])
            "[#{replacement}/#{parts.join('/')}]"
          end
          node['name'] = display if node['name'].to_s.empty? && display
        end
        node.each { |key, value| walk.call(value) unless key == 'formula' }
      when Array then node.each { |value| walk.call(value) }
      end
    end
    walk.call(spec) unless aliases.empty? && warehouse_prefixes.empty?

    raise "warehouse columns not found in catalog: #{unresolved.uniq.join(', ')}" if unresolved.any?
    { rewritten: rewritten, rekeyed: rekeyed, reprefixed: reprefixed,
      dropped: dropped, connection_modes: modes }
  end
end
