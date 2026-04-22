# frozen_string_literal: true

require "a3/domain/branch_namespace"
require "open3"
require "pathname"

module A3
  module Infra
    class InheritedParentStateResolver
      Snapshot = Struct.new(:ref, :heads_by_slot, keyword_init: true) do
        def fingerprint
          heads_by_slot.sort_by { |slot, _head| slot.to_s }.map { |slot, head| "#{slot}=#{head}" }.join("|")
        end

        def to_h
          { "inherited_parent_ref" => ref, "inherited_parent_state_fingerprint" => fingerprint }
        end
      end

      def initialize(repo_sources:, branch_namespace: ENV.fetch("A2O_BRANCH_NAMESPACE", ENV.fetch("A3_BRANCH_NAMESPACE", nil)))
        @repo_sources = repo_sources.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
        @branch_namespace = A3::Domain::BranchNamespace.normalize(branch_namespace)
      end

      def snapshot_for(task:, phase:)
        ref = inherited_parent_ref_for(task: task, phase: phase)
        return nil unless ref

        heads_by_slot = resolve_heads(ref: ref, repo_slots: inherited_repo_slots_for(task))
        return nil if heads_by_slot.empty?

        Snapshot.new(ref: ref, heads_by_slot: heads_by_slot)
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

      def resolve_heads(ref:, repo_slots:)
        Array(repo_slots).map(&:to_sym).each_with_object({}) do |slot, heads|
          source_root = @repo_sources[slot]
          next unless source_root

          head = resolve_head(source_root: source_root, ref: ref)
          return {} unless head

          heads[slot.to_s] = head
        end.freeze
      end

      def inherited_repo_slots_for(task)
        @repo_sources.keys
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

    end
  end
end
