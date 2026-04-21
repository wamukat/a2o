# frozen_string_literal: true

require "open3"
require "pathname"

module A3
  module Infra
    class InheritedParentStateResolver
      Snapshot = Struct.new(:ref, :head, keyword_init: true) do
        def to_h
          { "inherited_parent_ref" => ref, "inherited_parent_head" => head }
        end
      end

      def initialize(repo_sources:, branch_namespace: ENV.fetch("A2O_BRANCH_NAMESPACE", ENV.fetch("A3_BRANCH_NAMESPACE", nil)))
        @repo_sources = repo_sources.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
        @branch_namespace = normalize_branch_namespace(branch_namespace)
      end

      def snapshot_for(task:, phase:)
        ref = inherited_parent_ref_for(task: task, phase: phase)
        return nil unless ref

        head = resolve_consistent_head(ref: ref, repo_slots: task.edit_scope)
        return nil unless head

        Snapshot.new(ref: ref, head: head)
      end

      private

      def inherited_parent_ref_for(task:, phase:)
        return nil unless task.kind == :child
        return nil if task.parent_ref.to_s.empty?

        phase_name = phase&.to_sym
        return nil unless %i[implementation verification].include?(phase_name)
        return nil if phase_name == :verification && custom_verification_source?(task)

        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << task.parent_ref.tr("#", "-")
        parts.join("/")
      end

      def custom_verification_source?(task)
        source_ref = task.verification_source_ref.to_s.strip
        return false if source_ref.empty?

        source_ref != inherited_parent_ref_for(task: task, phase: :implementation)
      end

      def resolve_consistent_head(ref:, repo_slots:)
        heads = Array(repo_slots).map(&:to_sym).filter_map do |slot|
          source_root = @repo_sources[slot]
          next unless source_root

          resolve_head(source_root: source_root, ref: ref)
        end.uniq
        return nil unless heads.size == 1

        heads.first
      end

      def resolve_head(source_root:, ref:)
        stdout, _stderr, status = Open3.capture3(
          "git",
          "-c",
          "safe.directory=#{source_root}",
          "-C",
          source_root.to_s,
          "rev-parse",
          "--verify",
          "#{ref}^{commit}"
        )
        return nil unless status.success?

        stdout.strip
      end

      def normalize_branch_namespace(value)
        normalized = value.to_s.strip.gsub(%r{[^A-Za-z0-9._/-]}, "-").gsub(%r{/+}, "/").gsub(%r{\A/+|/+\z}, "")
        normalized = normalized.split("/").map { |part| part.sub(/\Aa3(?:-|\z)/, "") }.reject(&:empty?).join("/")
        normalized.empty? ? nil : normalized
      end
    end
  end
end
