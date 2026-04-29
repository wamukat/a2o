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
      INDEX_START = "<!-- a2o:index:start -->"
      INDEX_END = "<!-- a2o:index:end -->"

      Document = Struct.new(:path, :absolute_path, :metadata, :body, keyword_init: true) do
        def title = metadata["title"]
        def category = metadata["category"]
        def status = metadata["status"]
        def related_requirements = Array(metadata["related_requirements"])
        def source_issues = Array(metadata["source_issues"])
        def related_tickets = Array(metadata["related_tickets"])
        def authorities = Array(metadata["authorities"])
      end

      Diagnostic = Struct.new(:severity, :path, :field, :message, keyword_init: true)
      ManagedIndexBlock = Struct.new(:path, :content, keyword_init: true)
      MirrorDebt = Struct.new(:source_path, :language, :expected_path, keyword_init: true)
      AuthoritySource = Struct.new(:name, :source, :exists, :path, keyword_init: true)

      attr_reader :documents, :diagnostics, :managed_index_blocks, :authorities, :mirror_debt, :authority_sources

      def self.load(repo_root:, docs_config:)
        new(repo_root: repo_root, docs_config: docs_config).load
      end

      def initialize(repo_root:, docs_config:)
        @repo_root = File.expand_path(repo_root)
        @docs_config = stringify_keys(docs_config || {})
        @documents = []
        @diagnostics = []
        @managed_index_blocks = []
        @authorities = stringify_keys(@docs_config.fetch("authorities", {}))
        @mirror_debt = []
        @authority_sources = []
      end

      def load
        scan_markdown_files.each do |path|
          parse_document(path)
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

      attr_reader :repo_root, :docs_config

      def scan_markdown_files
        roots = [docs_config["root"]]
        stringify_keys(docs_config.fetch("categories", {})).each_value do |category|
          roots << stringify_keys(category)["path"]
        end
        roots.compact.map(&:to_s).reject(&:empty?).flat_map do |relative_root|
          absolute_root = safe_repo_path(relative_root)
          next [] unless absolute_root && File.directory?(absolute_root)

          Dir.glob(File.join(absolute_root, "**", "*.md")).sort
        end.uniq
      end

      def parse_document(path)
        relative_path = repo_relative_path(path)
        content = File.read(path, mode: "r:UTF-8")
        unless content.valid_encoding?
          diagnostic(:blocked, relative_path, nil, "document must be UTF-8 text")
          return
        end
        metadata, body = split_front_matter(content, relative_path)
        metadata = validate_metadata(metadata, relative_path)
        documents << Document.new(path: relative_path, absolute_path: path, metadata: metadata, body: body)
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
        paths = [docs_config["index"]]
        stringify_keys(docs_config.fetch("categories", {})).each_value do |category|
          paths << stringify_keys(category)["index"]
        end
        paths.compact.map(&:to_s).reject(&:empty?).uniq.each do |relative_path|
          absolute_path = safe_repo_path(relative_path)
          next unless absolute_path && File.file?(absolute_path)

          content = File.read(absolute_path, mode: "r:UTF-8")
          block = managed_index_block(content)
          next unless block

          managed_index_blocks << ManagedIndexBlock.new(path: relative_path, content: block)
        end
      end

      def managed_index_block(content)
        start_index = content.index(INDEX_START)
        return nil unless start_index

        body_start = start_index + INDEX_START.length
        end_index = content.index(INDEX_END, body_start)
        return nil unless end_index

        content[body_start...end_index].strip
      end

      def record_mirror_debt
        languages = stringify_keys(docs_config.fetch("languages", {}))
        impact_policy = stringify_keys(docs_config.fetch("impactPolicy", {}))
        canonical = languages["canonical"] || languages["primary"]
        mirrored = languages["mirrored"] || languages["secondary"] || []
        policy = (impact_policy["mirrorPolicy"] || languages["policy"]).to_s
        return unless canonical.is_a?(String) && !canonical.empty?
        return unless mirrored.is_a?(Array) && mirrored.any?
        return if policy == "canonical_only"

        existing_paths = documents.map(&:path).to_set
        documents.each do |document|
          parts = document.path.split("/")
          language_index = parts.index(canonical)
          next unless language_index

          mirrored.each do |language|
            expected_parts = parts.dup
            expected_parts[language_index] = language.to_s
            expected_path = expected_parts.join("/")
            next if existing_paths.include?(expected_path)

            mirror_debt << MirrorDebt.new(source_path: document.path, language: language.to_s, expected_path: expected_path)
          end
        end
      end

      def resolve_authority_sources
        authorities.keys.sort.each do |name|
          declaration = stringify_keys(authorities.fetch(name, {}))
          source = declaration["source"].to_s
          next if source.empty?

          absolute_path = safe_repo_path(source)
          exists = !!(absolute_path && File.exist?(absolute_path))
          authority_sources << AuthoritySource.new(
            name: name,
            source: source,
            exists: exists,
            path: absolute_path && repo_relative_path(absolute_path)
          )
          next if exists

          diagnostic(:warning, source, "authorities.#{name}.source", "authority source is declared but missing")
        end
      end

      def safe_repo_path(relative_path)
        return nil if Pathname.new(relative_path).absolute?

        absolute_path = File.expand_path(relative_path, repo_root)
        return nil unless absolute_path == repo_root || absolute_path.start_with?("#{repo_root}#{File::SEPARATOR}")

        absolute_path
      end

      def repo_relative_path(path)
        Pathname.new(path).relative_path_from(Pathname.new(repo_root)).to_s
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
