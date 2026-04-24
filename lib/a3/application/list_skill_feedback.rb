# frozen_string_literal: true

module A3
  module Application
    class ListSkillFeedback
      Entry = Struct.new(:task_ref, :run_ref, :phase, :category, :summary, :target, :repo_scope, :skill_path, :confidence, keyword_init: true)

      def initialize(run_repository:)
        @run_repository = run_repository
      end

      def call
        @run_repository.all.flat_map do |run|
          run.phase_records.flat_map do |record|
            Array(record.execution_record&.skill_feedback).map do |feedback|
              build_entry(run: run, phase: record.phase, feedback: feedback)
            end
          end
        end
      end

      private

      def build_entry(run:, phase:, feedback:)
        proposal = feedback["proposal"].is_a?(Hash) ? feedback["proposal"] : {}
        Entry.new(
          task_ref: run.task_ref,
          run_ref: run.ref,
          phase: phase.to_sym,
          category: feedback["category"],
          summary: feedback["summary"],
          target: proposal["target"],
          repo_scope: feedback["repo_scope"],
          skill_path: feedback["skill_path"],
          confidence: feedback["confidence"]
        )
      end
    end
  end
end
