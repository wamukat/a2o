# frozen_string_literal: true

require "fileutils"
require "pathname"
require "set"
require "yaml"

module A3
  module Domain
    class ProjectDocsUpdater
      INDEX_BLOCK = /
        <!--\s*a2o-docs-index:start(?:\s+category=(?<category>[A-Za-z0-9_-]+))?\s*-->
        (?<body>.*?)
        <!--\s*a2o-docs-index:end\s*-->
      /mx.freeze

      ARRAY_FIELDS = %w[
        related_requirements
        source_issues
        related_tickets
        authorities
        audience
        owners
        supersedes
      ].freeze

      DEFAULT_STATUS = "active"

      Diagnostic = Struct.new(:severity, :path, :field, :message, keyword_init: true)
      Result = Struct.new(:updated_paths, :diagnostics, keyword_init: true) do
        def changed?
          updated_paths.any?
        end
      end

      def self.update_document(repo_root:, docs_config:, category:, title:, body: nil, relative_path: nil, metadata: {}, surface_id: nil, repo_roots: nil)
        new(repo_root: repo_root, docs_config: docs_config, surface_id: surface_id, repo_roots: repo_roots).update_document(
          category: category,
          title: title,
          body: body,
          relative_path: relative_path,
          metadata: metadata
        )
      end

      def initialize(repo_root:, docs_config:, surface_id: nil, repo_roots: nil)
        @repo_root = File.expand_path(repo_root)
        @repo_roots = stringify_keys(repo_roots || {}).transform_values { |path| File.expand_path(path.to_s) }
        @docs_config = stringify_keys(docs_config || {})
        @surface_id = surface_id && surface_id.to_s
        @diagnostics = []
        @updated_paths = []
        @surface_config = selected_surface_config
        @repo_root = repo_root_for_surface
      end

      def update_document(category:, title:, body: nil, relative_path: nil, metadata: {})
        category = category.to_s
        title = title.to_s.strip
        metadata = stringify_keys(metadata || {})
        target_path = resolve_document_path(category: category, title: title, relative_path: relative_path)
        return result unless target_path

        absolute_path = safe_repo_path(target_path)
        return result unless absolute_path

        existing_metadata = {}
        existing_body = ""
        if File.file?(absolute_path)
          existing_metadata, existing_body = split_front_matter(File.read(absolute_path, mode: "r:UTF-8"), target_path)
        end

        next_metadata = merge_metadata(
          existing_metadata,
          metadata.merge(
            "title" => title,
            "category" => category,
            "status" => metadata.fetch("status", existing_metadata["status"] || DEFAULT_STATUS)
          )
        )
        next_body = body.nil? ? existing_body : ensure_trailing_newline(body.to_s)
        next_body = "\n" if next_body.empty?
        write_if_changed(absolute_path, render_document(next_metadata, next_body))
        update_managed_indexes(category: category, document_path: target_path, title: title)
        result
      end

      private

      attr_reader :repo_root, :repo_roots, :docs_config, :surface_id, :surface_config, :diagnostics, :updated_paths

      def result
        Result.new(updated_paths: updated_paths.uniq.freeze, diagnostics: diagnostics.freeze)
      end

      def resolve_document_path(category:, title:, relative_path:)
        categories = stringify_keys(docs_config.fetch("categories", {}))
        categories = stringify_keys(surface_config.fetch("categories", {})) if surface_config
        category_config = stringify_keys(categories.fetch(category, {}))
        category_root = category_config["path"]
        unless category_root.is_a?(String) && !category_root.strip.empty?
          diagnostic(:blocked, nil, "docs.categories.#{category}.path", "docs category path is not configured")
          return nil
        end

        path = relative_path.to_s.strip
        if path.split(/[\\\/]+/).include?("..")
          diagnostic(:blocked, path, nil, "docs path must stay inside the configured category path")
          return nil
        end
        path = File.join(category_root, "#{slug(title)}.md") if path.empty?
        path = File.join(category_root, path) unless path.start_with?("#{category_root}/") || path == category_root
        unless path.end_with?(".md")
          diagnostic(:blocked, path, nil, "docs update target must be a Markdown file")
          return nil
        end
        safe_repo_path(path) ? path : nil
      end

      def update_managed_indexes(category:, document_path:, title:)
        index_paths = configured_index_paths(category)
        index_paths.each do |index_path|
          absolute_path = safe_repo_path(index_path)
          next unless absolute_path
          next unless File.file?(absolute_path)

          content = File.read(absolute_path, mode: "r:UTF-8")
          matches = managed_index_matches(content, category)
          all_matches = content.to_enum(:scan, INDEX_BLOCK).map { Regexp.last_match }
          if all_matches.empty?
            diagnostic(:review_finding, index_path, nil, "index has no a2o-docs-index managed block; skipping broad rewrite")
            next
          end
          if matches.empty?
            diagnostic(:review_finding, index_path, "category", "index has no a2o-docs-index block for category #{category}; skipping broad rewrite")
            next
          end
          if matches.length > 1
            diagnostic(:review_finding, index_path, "category", "index has multiple eligible a2o-docs-index blocks for category #{category}; skipping ambiguous rewrite")
            next
          end

          match = matches.first
          index_dir = File.dirname(index_path)
          replacement = render_index_block(category: match[:category], body: match[:body], index_dir: index_dir, document_path: document_path, title: title)
          next_content = "#{content[0...match.begin(0)]}#{replacement}#{content[match.end(0)..]}"
          write_if_changed(absolute_path, next_content)
        end
      end

      def managed_index_matches(content, category)
        content.to_enum(:scan, INDEX_BLOCK).filter_map do
          match = Regexp.last_match
          block_category = match[:category]
          match if block_category.nil? || block_category == category
        end
      end

      def render_index_block(category:, body:, index_dir:, document_path:, title:)
        entries = parse_index_entries(body)
        entries[relative_link(from_dir: index_dir, target_path: document_path)] = title
        rendered = entries.sort_by { |path, entry_title| [entry_title.downcase, path] }
                          .map { |path, entry_title| "- [#{entry_title}](#{path})" }
                          .join("\n")
        marker = category ? " category=#{category}" : ""
        "<!-- a2o-docs-index:start#{marker} -->\n#{rendered}\n<!-- a2o-docs-index:end -->"
      end

      def parse_index_entries(body)
        body.to_s.lines.each_with_object({}) do |line, entries|
          match = line.match(/\A\s*-\s+\[(?<title>[^\]]+)\]\((?<path>[^)]+)\)\s*\z/)
          next unless match

          entries[match[:path]] = match[:title]
        end
      end

      def configured_index_paths(category)
        active_config = surface_config || docs_config
        paths = [active_config["index"]]
        category_config = stringify_keys(active_config.fetch("categories", {}).fetch(category, {}))
        paths << category_config["index"]
        paths.compact.map(&:to_s).reject(&:empty?).uniq
      end

      def split_front_matter(content, _relative_path)
        return [{}, content] unless content.start_with?("---\n")

        closing_index = content.index("\n---\n", 4)
        return [{}, content] unless closing_index

        yaml_text = content[4...closing_index]
        body = content[(closing_index + 5)..] || ""
        metadata = YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
        [metadata.is_a?(Hash) ? stringify_keys(metadata) : {}, body]
      rescue Psych::Exception
        [{}, content]
      end

      def merge_metadata(existing, incoming)
        merged = stringify_keys(existing)
        stringify_keys(incoming).each do |field, value|
          next if value.nil?

          if ARRAY_FIELDS.include?(field)
            entries = Array(merged[field]) + Array(value)
            merged[field] = entries.map(&:to_s).map(&:strip).reject(&:empty?).uniq
          else
            text = value.to_s.strip
            merged[field] = text unless text.empty?
          end
        end
        merged
      end

      def render_document(metadata, body)
        yaml = YAML.dump(metadata).sub(/\A---\n/, "---\n")
        "#{yaml}---\n\n#{ensure_trailing_newline(body)}"
      end

      def relative_link(from_dir:, target_path:)
        from = Pathname.new(from_dir == "." ? "" : from_dir)
        target = Pathname.new(target_path)
        target.relative_path_from(from).to_s
      rescue ArgumentError
        target_path
      end

      def write_if_changed(absolute_path, content)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        return if File.file?(absolute_path) && File.read(absolute_path, mode: "r:UTF-8") == content

        File.write(absolute_path, content)
        updated_paths << repo_relative_path(absolute_path)
      end

      def safe_repo_path(relative_path)
        if Pathname.new(relative_path).absolute?
          diagnostic(:blocked, relative_path, nil, "docs path must be relative to the repo slot")
          return nil
        end

        absolute_path = File.expand_path(relative_path, repo_root)
        unless absolute_path == repo_root || absolute_path.start_with?("#{repo_root}#{File::SEPARATOR}")
          diagnostic(:blocked, relative_path, nil, "docs path must stay inside the repo slot")
          return nil
        end
        absolute_path
      end

      def selected_surface_config
        surfaces = stringify_keys(docs_config.fetch("surfaces", {}))
        return nil if surfaces.empty?

        if surface_id && surfaces.key?(surface_id)
          return stringify_keys(surfaces.fetch(surface_id))
        end
        if surface_id
          diagnostic(:blocked, nil, "docs.surfaces.#{surface_id}", "docs surface is not configured")
          return nil
        end
        nil
      end

      def repo_root_for_surface
        active_config = surface_config || docs_config
        slot = active_config["repoSlot"] || docs_config["repoSlot"]
        return repo_roots.fetch(slot.to_s, repo_root) if slot

        repo_root
      end

      def repo_relative_path(path)
        Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
      end

      def slug(value)
        value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "").then { |text| text.empty? ? "document" : text }
      end

      def ensure_trailing_newline(value)
        value.end_with?("\n") ? value : "#{value}\n"
      end

      def diagnostic(severity, path, field, message)
        diagnostics << Diagnostic.new(severity: severity, path: path, field: field, message: message)
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, entry), memo| memo[key.to_s] = stringify_keys(entry) }
        when Array
          value.map { |entry| stringify_keys(entry) }
        else
          value
        end
      end
    end
  end
end
