# frozen_string_literal: true

require "uri"

module A3
  module Domain
    module SourceRemote
      module_function

      def normalize(value)
        compact = compact_value(value)
        return nil unless compact.is_a?(Hash) && compact.any?

        compact
      end

      def external_reference_payload(value)
        compact = normalize(value)
        return nil unless compact

        provider = lookup(compact, "provider")
        url = lookup(compact, "url", "remoteUrl", "remote_url")
        display_ref = lookup(compact, "displayRef", "display_ref", "display")
        instance_url = lookup(compact, "instanceUrl", "instance_url")
        resource_type = lookup(compact, "resourceType", "resource_type") || "issue"
        project_key = lookup(compact, "projectKey", "project_key", "repository", "repo")
        issue_key = lookup(compact, "issueKey", "issue_key", "number", "id")
        title = lookup(compact, "title", "remoteTitle", "remote_title")

        if display_ref && (!project_key || !issue_key)
          parsed_project_key, parsed_issue_key = parse_display_ref(display_ref)
          project_key ||= parsed_project_key
          issue_key ||= parsed_issue_key
        end
        if url
          instance_url ||= origin_from_url(url)
          project_key ||= github_project_key_from_url(url) if provider.to_s == "github"
          issue_key ||= issue_key_from_url(url)
        end
        display_ref ||= [project_key, issue_key].compact.join("#") if project_key && issue_key

        required = [provider, instance_url, project_key, issue_key, display_ref, url]
        return nil if required.any? { |entry| blank_compact_value?(entry) }

        payload = {
          "provider" => provider,
          "instanceUrl" => instance_url,
          "resourceType" => resource_type,
          "projectKey" => project_key,
          "issueKey" => issue_key,
          "displayRef" => display_ref,
          "url" => url
        }
        payload["title"] = title if title
        payload
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

      def blank_compact_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def lookup(hash, *keys)
        keys.each do |key|
          value = hash[key]
          return value.to_s.strip unless blank_compact_value?(value)
        end
        nil
      end

      def parse_display_ref(value)
        match = value.to_s.strip.match(/\A(.+?)#([^#]+)\z/)
        return [nil, nil] unless match

        [match[1], match[2]]
      end

      def origin_from_url(value)
        uri = URI.parse(value.to_s)
        return nil unless uri.scheme && uri.host

        "#{uri.scheme}://#{uri.host}"
      rescue URI::InvalidURIError
        nil
      end

      def github_project_key_from_url(value)
        uri = URI.parse(value.to_s)
        parts = uri.path.to_s.split("/").reject(&:empty?)
        return nil unless parts.size >= 2

        "#{parts[0]}/#{parts[1]}"
      rescue URI::InvalidURIError
        nil
      end

      def issue_key_from_url(value)
        uri = URI.parse(value.to_s)
        parts = uri.path.to_s.split("/").reject(&:empty?)
        issue_index = parts.index("issues") || parts.index("pull")
        return nil unless issue_index && parts[issue_index + 1]

        parts[issue_index + 1]
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
