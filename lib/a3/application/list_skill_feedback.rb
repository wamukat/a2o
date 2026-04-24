# frozen_string_literal: true

module A3
  module Application
    class ListSkillFeedback
      Entry = Struct.new(
        :task_ref,
        :run_ref,
        :phase,
        :category,
        :summary,
        :target,
        :repo_scope,
        :skill_path,
        :confidence,
        :state,
        :evidence,
        :suggested_patch,
        :group_key,
        keyword_init: true
      )

      Group = Struct.new(:key, :entries, keyword_init: true) do
        def count
          entries.size
        end

        def representative
          entries.first
        end
      end

      def initialize(run_repository:)
        @run_repository = run_repository
      end

      def call(state: nil, target: nil, group: false)
        entries = @run_repository.all.flat_map do |run|
          run.phase_records.flat_map do |record|
            Array(record.execution_record&.skill_feedback).map do |feedback|
              build_entry(run: run, phase: record.phase, feedback: feedback)
            end
          end
        end
        entries = entries.select { |entry| entry.state == state } if state
        entries = entries.select { |entry| entry.target == target } if target
        return grouped(entries) if group

        entries
      end

      private

      def grouped(entries)
        entries
          .group_by(&:group_key)
          .values
          .map { |items| Group.new(key: items.first.group_key, entries: items) }
      end

      def build_entry(run:, phase:, feedback:)
        proposal = A3::Domain::SkillFeedback.proposal_for(feedback)
        Entry.new(
          task_ref: run.task_ref,
          run_ref: run.ref,
          phase: phase.to_sym,
          category: feedback["category"],
          summary: feedback["summary"],
          target: proposal["target"],
          repo_scope: feedback["repo_scope"],
          skill_path: feedback["skill_path"],
          confidence: feedback["confidence"],
          state: A3::Domain::SkillFeedback.state_for(feedback),
          evidence: feedback["evidence"].is_a?(Hash) ? feedback["evidence"] : {},
          suggested_patch: proposal["suggested_patch"],
          group_key: A3::Domain::SkillFeedback.group_key_for(feedback)
        )
      end
    end
  end
end
