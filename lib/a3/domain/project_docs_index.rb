# frozen_string_literal: true

require "pathname"
require "set"
require "yaml"

module A3
  module Domain
    class ProjectDocsIndex
      AUTHORITY_PRECEDENCE = %w[authority_source docs evidence_artifacts ticket_text].freeze
      FRONT_MATTER_FIELDS = %w[
        title
        category
        status
        related_requirements
        source_issues
        related_tickets
        authorities
        audience
        owners
        supersedes
      ].freeze
      ARRAY_FIELDS = %w[
        related_requirements
        source_issues
        related_tickets
        authorities
        audience
        owners
        supersedes
      ].freeze
      LIFECYCLE_FIELDS = %w[
        kanban_status
        current_state
        run_status
        review_disposition
        merge_status
        lane
      ].freeze
      INDEX_BLOCK = /<!--\s*a2o-docs-index:start(?:\s+category=(?<category>[A-Za-z0-9_-]+))?\s*-->(?<body>.*?)<!--\s*a2o-docs-index:end\s*-->/m.freeze
      LEGACY_INDEX_START = "<!-- a2o:index:start -->"
      LEGACY_INDEX_END = "<!-- a2o:index:end -->"

      Surface = Struct.new(:id, :repo_slot, :role, :repo_root, :root, :index, :categories, :languages, :policy, :impact_policy, keyword_init: true) do
        def to_h
          {
            id: id,
            repo_slot: repo_slot,
            role: role,
            root: root,
            index: index,
            categories: categories.keys.sort,
            languages: languages,
            policy: policy,
            impact_policy: impact_policy
          }.compact
        end
      end

      Document = Struct.new(:path, :absolute_path, :metadata, :body, :surface_id, :repo_slot, :role, keyword_init: true) do
        def title
          metadata["title"]
        end

        def category
          metadata["category"]
        end

        def status
          metadata["status"]
        end

        def related_requirements
          Array(metadata["related_requirements"])
        end

        def source_issues
          Array(metadata["source_issues"])
        end

        def related_tickets
          Array(metadata["related_tickets"])
        end

        def authorities
          Array(metadata["authorities"])
        end
      end

      Diagnostic = Struct.new(:severity, :path, :field, :message, keyword_init: true)
      ManagedIndexBlock = Struct.new(:path, :content, :category, :surface_id, :repo_slot, :role, keyword_init: true)
      MirrorDebt = Struct.new(:source_path, :language, :expected_path, :surface_id, :repo_slot, :role, keyword_init: true) do
        def to_h
          {
            source_path: source_path,
            language: language,
            expected_path: expected_path,
            surface_id: surface_id == "default" ? nil : surface_id,
            repo_slot: repo_slot,
            role: role
          }.compact
        end
      end
      AuthoritySource = Struct.new(:name, :source, :exists, :path, :repo_slot, keyword_init: true) do
        def to_h
          {
            name: name,
            source: source,
            exists: exists,
            path: path,
            repo_slot: repo_slot
          }.compact
        end
      end

      attr_reader :documents, :diagnostics, :managed_index_blocks, :authorities, :mirror_debt, :authority_sources, :surfaces

      def self.load(repo_root:, docs_config:, repo_roots: nil)
        new(repo_root: repo_root, docs_config: docs_config, repo_roots: repo_roots).load
      end

      def initialize(repo_root:, docs_config:, repo_roots: nil)
        @repo_root = File.expand_path(repo_root)
        @repo_roots = stringify_keys(repo_roots || {}).transform_values { |path| File.expand_path(path.to_s) }
        @docs_config = stringify_keys(docs_config || {})
        @documents = []
        @diagnostics = []
        @managed_index_blocks = []
        @authorities = stringify_keys(@docs_config.fetch("authorities", {}))
        @mirror_debt = []
        @authority_sources = []
        @surfaces = normalize_surfaces
      end

      def load
        surfaces.each do |surface|
          scan_markdown_files(surface).each do |path|
            parse_document(path, surface)
          end
        end
        load_managed_index_blocks
        resolve_authority_sources
        record_mirror_debt
        self
      end

      def by_category(category)
        documents.select { |document| document.category == category.to_s }
      end

      def by_related_requirement(ref)
        documents.select { |document| document.related_requirements.include?(ref.to_s) }
      end

      def by_related_ticket(ref)
        documents.select { |document| document.related_tickets.include?(ref.to_s) }
      end

      def by_source_issue(ref)
        documents.select { |document| document.source_issues.include?(ref.to_s) }
      end

      def by_authority(authority)
        documents.select { |document| document.authorities.include?(authority.to_s) }
      end

      def authority(name)
        authorities.fetch(name.to_s, nil)
      end

      def authority_precedence(_name = nil)
        AUTHORITY_PRECEDENCE
      end

      private

      attr_reader :repo_root, :repo_roots, :docs_config

      def normalize_surfaces
        raw_surfaces = stringify_keys(docs_config.fetch("surfaces", {}))
        if raw_surfaces.any?
          raw_surfaces.keys.sort.map do |id|
            surface_config = stringify_keys(raw_surfaces.fetch(id, {}))
            repo_slot = surface_config["repoSlot"] || docs_config["repoSlot"]
            Surface.new(
              id: id,
              repo_slot: repo_slot,
              role: surface_config["role"],
              repo_root: repo_root_for_slot(repo_slot),
              root: surface_config["root"],
              index: surface_config["index"],
              categories: stringify_keys(surface_config.fetch("categories", {})),
              languages: stringify_keys(surface_config.fetch("languages", docs_config.fetch("languages", {}))),
              policy: stringify_keys(surface_config.fetch("policy", docs_config.fetch("policy", {}))),
              impact_policy: stringify_keys(surface_config.fetch("impactPolicy", docs_config.fetch("impactPolicy", {})))
            )
          end
        else
          repo_slot = docs_config["repoSlot"]
          [
            Surface.new(
              id: "default",
              repo_slot: repo_slot,
              role: docs_config["role"],
              repo_root: repo_root_for_slot(repo_slot),
              root: docs_config["root"],
              index: docs_config["index"],
              categories: stringify_keys(docs_config.fetch("categories", {})),
              languages: stringify_keys(docs_config.fetch("languages", {})),
              policy: stringify_keys(docs_config.fetch("policy", {})),
              impact_policy: stringify_keys(docs_config.fetch("impactPolicy", {}))
            )
          ]
        end
      end

      def repo_root_for_slot(repo_slot)
        repo_roots.fetch(repo_slot.to_s, repo_root)
      end

      def scan_markdown_files(surface)
        roots = surface.id == "default" || surface.categories.empty? ? [surface.root] : []
        surface.categories.each_value do |category|
          roots << stringify_keys(category)["path"]
        end
        roots.compact.map(&:to_s).reject(&:empty?).flat_map do |relative_root|
          absolute_root = safe_repo_path(relative_root, surface.repo_root)
          next [] unless absolute_root && File.directory?(absolute_root)

          Dir.glob(File.join(absolute_root, "**", "*.md")).sort
        end.uniq
      end

      def parse_document(path, surface)
        relative_path = repo_relative_path(path, surface.repo_root)
        content = File.read(path, mode: "r:UTF-8")
        unless content.valid_encoding?
          diagnostic(:blocked, relative_path, nil, "document must be UTF-8 text")
          return
        end
        metadata, body = split_front_matter(content, relative_path)
        metadata = validate_metadata(metadata, relative_path)
        documents << Document.new(path: relative_path, absolute_path: path, metadata: metadata, body: body, surface_id: surface.id, repo_slot: surface.repo_slot, role: surface.role)
      end

      def split_front_matter(content, relative_path)
        return [{}, content] unless content.start_with?("---\n")

        marker = "\n---\n"
        closing_index = content.index(marker, 4)
        unless closing_index
          diagnostic(:blocked, relative_path, nil, "front matter is missing closing --- marker")
          return [{}, content]
        end
        yaml_text = content[4...closing_index]
        body = content[(closing_index + marker.length)..] || ""
        metadata = YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
        unless metadata.nil? || metadata.is_a?(Hash)
          diagnostic(:blocked, relative_path, nil, "front matter must be a mapping")
          return [{}, body]
        end
        [stringify_keys(metadata || {}), body]
      rescue Psych::Exception => e
        diagnostic(:blocked, relative_path, nil, "front matter YAML is invalid: #{e.message}")
        [{}, content]
      end

      def validate_metadata(metadata, relative_path)
        clean = {}
        metadata.each do |field, value|
          if LIFECYCLE_FIELDS.include?(field)
            diagnostic(:blocked, relative_path, field, "front matter must not duplicate lifecycle state")
            next
          end
          if ARRAY_FIELDS.include?(field)
            if value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
              clean[field] = value
            else
              diagnostic(:blocked, relative_path, field, "front matter #{field} must be an array of non-empty strings")
            end
            next
          end
          if FRONT_MATTER_FIELDS.include?(field)
            if value.is_a?(String) && !value.strip.empty?
              clean[field] = value
            else
              diagnostic(:blocked, relative_path, field, "front matter #{field} must be a non-empty string")
            end
            next
          end
          clean[field] = value
        end
        clean
      end

      def load_managed_index_blocks
        surfaces.each do |surface|
          paths = [surface.index]
          surface.categories.each_value do |category|
            paths << stringify_keys(category)["index"]
          end
          paths.compact.map(&:to_s).reject(&:empty?).uniq.each do |relative_path|
            absolute_path = safe_repo_path(relative_path, surface.repo_root)
            next unless absolute_path && File.file?(absolute_path)

            content = File.read(absolute_path, mode: "r:UTF-8")
            extract_managed_index_blocks(content).each do |block|
              managed_index_blocks << ManagedIndexBlock.new(path: relative_path, content: block.fetch(:content), category: block.fetch(:category), surface_id: surface.id, repo_slot: surface.repo_slot, role: surface.role)
            end
          end
        end
      end

      def extract_managed_index_blocks(content)
        blocks = content.to_enum(:scan, INDEX_BLOCK).map do
          match = Regexp.last_match
          { content: match[:body].strip, category: match[:category] }
        end
        return blocks unless blocks.empty?

        start_index = content.index(LEGACY_INDEX_START)
        return [] unless start_index

        body_start = start_index + LEGACY_INDEX_START.length
        end_index = content.index(LEGACY_INDEX_END, body_start)
        return [] unless end_index

        [{ content: content[body_start...end_index].strip, category: nil }]
      end

      def record_mirror_debt
        surfaces.each do |surface|
          canonical = surface.languages["canonical"] || surface.languages["primary"]
          mirrored = surface.languages["mirrored"] || surface.languages["secondary"] || []
          policy = (surface.impact_policy["mirrorPolicy"] || surface.languages["policy"]).to_s
          next unless canonical.is_a?(String) && !canonical.empty?
          next unless mirrored.is_a?(Array) && mirrored.any?
          next if policy == "canonical_only"

          surface_documents = documents.select { |document| document.surface_id == surface.id }
          existing_paths = surface_documents.map(&:path).to_set
          surface_documents.each do |document|
            parts = document.path.split("/")
            language_index = parts.index(canonical)
            next unless language_index

            mirrored.each do |language|
              expected_parts = parts.dup
              expected_parts[language_index] = language.to_s
              expected_path = expected_parts.join("/")
              next if existing_paths.include?(expected_path)

              mirror_debt << MirrorDebt.new(source_path: document.path, language: language.to_s, expected_path: expected_path, surface_id: surface.id, repo_slot: surface.repo_slot, role: surface.role)
            end
          end
        end
      end

      def resolve_authority_sources
        authorities.keys.sort.each do |name|
          declaration = stringify_keys(authorities.fetch(name, {}))
          source = declaration["source"].to_s
          next if source.empty?

          repo_slot = declaration["repoSlot"]
          authority_repo_root = repo_root_for_slot(repo_slot)
          absolute_path = safe_repo_path(source, authority_repo_root)
          exists = !!(absolute_path && File.exist?(absolute_path))
          authority_sources << AuthoritySource.new(
            name: name,
            source: source,
            exists: exists,
            path: absolute_path && repo_relative_path(absolute_path, authority_repo_root),
            repo_slot: repo_slot
          )
          next if exists

          diagnostic(:warning, source, "authorities.#{name}.source", "authority source is declared but missing")
        end
      end

      def safe_repo_path(relative_path, base_root)
        return nil if Pathname.new(relative_path).absolute?

        absolute_path = File.expand_path(relative_path, base_root)
        return nil unless absolute_path == base_root || absolute_path.start_with?("#{base_root}#{File::SEPARATOR}")

        absolute_path
      end

      def repo_relative_path(path, base_root)
        Pathname.new(path).relative_path_from(Pathname.new(base_root)).to_s
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
