# frozen_string_literal: true

module A3
  module Domain
    class ProjectDocsImpactAnalyzer
      CATEGORY_KEYWORDS = {
        "architecture" => %w[architecture boundary component runtime scheduler workspace branch multi-repo multi-project],
        "shared_specs" => %w[shared spec schema protocol model prompt skill project-package],
        "interfaces" => %w[api cli command event config configuration interface],
        "data_model" => %w[database db migration table schema model],
        "acl" => %w[acl permission permissions role roles authorization authentication access],
        "external_api" => %w[openapi graphql webhook external api integration integrations],
        "features" => %w[feature user behavior ux],
        "operations" => %w[operation release deploy doctor diagnostic monitoring],
        "migration" => %w[migration compatibility upgrade breaking]
      }.freeze
      SHARED_SPEC_CATEGORIES = %w[shared_specs acl external_api].freeze

      CandidateDoc = Struct.new(:path, :title, :category, :reason, :excerpt, :surface_id, :repo_slot, :role, :expected_action, keyword_init: true)
      Decision = Struct.new(:decision, :categories, :matched_rules, :candidate_docs, :authorities, :authority_sources, :mirror_debt, :diagnostics, :surfaces, keyword_init: true) do
        def request_form
          {
            "decision" => decision,
            "categories" => categories,
            "matched_rules" => matched_rules,
            "surfaces" => surfaces.map { |surface| stringify_hash(surface.to_h) },
            "candidate_docs" => candidate_docs.map { |candidate| stringify_hash(candidate.to_h) },
            "authority_precedence" => A3::Domain::ProjectDocsIndex::AUTHORITY_PRECEDENCE,
            "authorities" => authorities,
            "authority_sources" => authority_sources.map { |source| stringify_hash(source.to_h) },
            "mirror_debt" => mirror_debt.map { |debt| stringify_hash(debt.to_h) },
            "diagnostics" => diagnostics.map { |diagnostic| stringify_hash(diagnostic.to_h) }
          }
        end

        private

        def stringify_hash(value)
          value.each_with_object({}) { |(key, entry), memo| memo[key.to_s] = entry }
        end
      end

      def initialize(docs_index:)
        @docs_index = docs_index
      end

      def analyze(task:, task_packet:, changed_files: {})
        @current_edit_scope = Array(task_packet.edit_scope.empty? ? task.edit_scope : task_packet.edit_scope)
        refs = trace_refs(task: task, task_packet: task_packet)
        matched = []
        candidates = []
        categories = matched_categories(task_packet: task_packet, changed_files: changed_files, matched_rules: matched)
        refs.each do |ref|
          add_candidates(candidates, @docs_index.by_related_requirement(ref), "related_requirement:#{ref}")
          add_candidates(candidates, @docs_index.by_related_ticket(ref), "related_ticket:#{ref}")
          add_candidates(candidates, @docs_index.by_source_issue(ref), "source_issue:#{ref}")
        end
        categories.each do |category|
          add_candidates(candidates, @docs_index.by_category(category), "category:#{category}")
        end
        shared_spec_categories(categories, task_packet).each do |category|
          add_candidates(candidates, @docs_index.by_category(category), "#{category}_constraint")
        end
        authorities = candidates.flat_map { |candidate| Array(candidate[:document].authorities) }.uniq.sort
        decision = decision_for(categories: categories, candidates: candidates, matched_rules: matched)
        Decision.new(
          decision: decision,
          categories: categories,
          matched_rules: matched.uniq,
          candidate_docs: candidates.map { |candidate| candidate_doc(candidate.fetch(:document), candidate.fetch(:reason)) },
          authorities: authorities.map { |name| { "name" => name, "declaration" => @docs_index.authority(name) }.compact },
          authority_sources: @docs_index.authority_sources,
          mirror_debt: @docs_index.mirror_debt,
          diagnostics: @docs_index.diagnostics,
          surfaces: @docs_index.surfaces
        )
      end

      private

      def trace_refs(task:, task_packet:)
        refs = [task.ref, task.parent_ref, *task.child_refs]
        text = [task_packet.title, task_packet.description].join("\n")
        refs.concat(text.scan(/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+/))
        refs.concat(text.scan(/[A-Z][A-Za-z0-9_-]*#\d+/))
        refs.compact.map(&:to_s).reject(&:empty?).uniq
      end

      def matched_categories(task_packet:, changed_files:, matched_rules:)
        text = [task_packet.title, task_packet.description, changed_files.values.flatten.join(" ")].join(" ").downcase
        CATEGORY_KEYWORDS.each_with_object([]) do |(category, keywords), categories|
          matched_keyword = keywords.find { |keyword| text.include?(keyword) }
          next unless matched_keyword

          categories << category
          matched_rules << "keyword:#{matched_keyword}->#{category}"
        end.uniq
      end

      def shared_spec_signal?(task_packet)
        [task_packet.title, task_packet.description].join(" ").downcase.match?(/shared|common|schema|protocol|prompt|skill|project-package/)
      end

      def shared_spec_categories(categories, task_packet)
        selected = categories & SHARED_SPEC_CATEGORIES
        selected << "shared_specs" if categories.include?("shared_specs")
        selected << "shared_specs" if shared_spec_signal?(task_packet)
        selected.uniq
      end

      def add_candidates(candidates, documents, reason)
        documents.each do |document|
          next unless document_applicable?(document)

          key = [document.surface_id, document.path, reason]
          next if candidates.any? { |candidate| [candidate.fetch(:document).surface_id, candidate.fetch(:document).path, candidate.fetch(:reason)] == key }

          candidates << { document: document, reason: reason }
        end
      end

      def decision_for(categories:, candidates:, matched_rules:)
        return "yes" if candidates.any?
        return "maybe" if categories.any? || matched_rules.any?

        "no"
      end

      def candidate_doc(document, reason)
        CandidateDoc.new(
          path: document.path,
          title: document.title,
          category: document.category,
          reason: reason,
          excerpt: excerpt(document.body),
          surface_id: document.surface_id,
          repo_slot: document.repo_slot,
          role: document.role,
          expected_action: document.role.to_s == "integration" ? "update_or_confirm_integration_docs" : "update_or_confirm_repo_docs"
        )
      end

      def document_applicable?(document)
        return true if document.role.to_s == "integration"
        return true if document.repo_slot.to_s.empty?

        scope = Array(@current_edit_scope).map(&:to_s)
        scope.empty? || scope.include?(document.repo_slot.to_s)
      end

      def excerpt(text)
        text.to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?).first.to_s[0, 600]
      end
    end
  end
end
