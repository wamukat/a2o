# frozen_string_literal: true

module A3
  module Domain
    module SourceRemote
      module_function

      def normalize(value)
        compact = compact_value(value)
        return nil unless compact.is_a?(Hash) && compact.any?

        compact
      end

      def summary(value)
        remote = normalize(value)
        return nil unless remote

        display = first_present(remote, "display_ref", "ref", "reference", "issue_ref", "external_ref", "key", "id")
        url = first_present(remote, "html_url", "web_url", "url")
        provider = first_present(remote, "provider", "kind", "source")
        parts = []
        parts << provider if provider
        parts << display if display
        parts << url if url && url != display
        return nil if parts.empty?

        parts.join(" ")
      end

      def markdown_block(value, heading: "Source remote")
        remote = normalize(value)
        return "" unless remote

        lines = ["", "#{heading}:"]
        %w[provider display_ref ref reference issue_ref external_ref url html_url web_url].each do |key|
          next unless remote.key?(key)

          lines << "- #{key}: #{remote.fetch(key)}"
        end
        (remote.keys - %w[provider display_ref ref reference issue_ref external_ref url html_url web_url]).sort.each do |key|
          value = remote.fetch(key)
          lines << "- #{key}: #{value}" unless value.is_a?(Hash) || value.is_a?(Array)
        end
        lines.join("\n")
      end

      def compact_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), memo|
            normalized_key = key.to_s.strip
            next if normalized_key.empty?

            normalized_value = compact_value(child)
            next if blank_compact_value?(normalized_value)

            memo[normalized_key] = normalized_value
          end
        when Array
          value.map { |child| compact_value(child) }.reject { |child| blank_compact_value?(child) }
        when NilClass
          nil
        else
          text = value.to_s.strip
          text.empty? ? nil : text
        end
      end

      def first_present(remote, *keys)
        keys.each do |key|
          value = remote[key]
          return value.to_s if value && !value.to_s.strip.empty?
        end
        nil
      end

      def blank_compact_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end
