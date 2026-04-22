# frozen_string_literal: true

require "a3/domain/deep_freezable"

module A3
  module Domain
    class BlockedDiagnosis
      include DeepFreezable

      attr_reader :task_ref, :run_ref, :phase, :outcome, :review_target, :source_descriptor, :scope_snapshot, :artifact_owner,
                  :expected_state, :observed_state, :failing_command, :diagnostic_summary, :infra_diagnostics

      def initialize(task_ref:, run_ref:, phase:, outcome:, review_target:, source_descriptor:, scope_snapshot:, artifact_owner:,
                     expected_state:, observed_state:, failing_command:, diagnostic_summary:, infra_diagnostics:)
        @task_ref = task_ref
        @run_ref = run_ref
        @phase = phase.to_sym
        @outcome = outcome.to_sym
        @review_target = review_target
        @source_descriptor = source_descriptor
        @scope_snapshot = scope_snapshot
        @artifact_owner = artifact_owner
        @expected_state = expected_state
        @observed_state = observed_state
        @failing_command = failing_command
        @diagnostic_summary = diagnostic_summary
        @infra_diagnostics = deep_freeze_value(infra_diagnostics)
        freeze
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          task_ref: record.fetch("task_ref"),
          run_ref: record.fetch("run_ref"),
          phase: record.fetch("phase"),
          outcome: record.fetch("outcome"),
          review_target: ReviewTarget.from_persisted_form(record.fetch("review_target")),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          scope_snapshot: ScopeSnapshot.from_persisted_form(record.fetch("scope_snapshot")),
          artifact_owner: ArtifactOwner.from_persisted_form(record.fetch("artifact_owner")),
          expected_state: record.fetch("expected_state"),
          observed_state: record.fetch("observed_state"),
          failing_command: record.fetch("failing_command"),
          diagnostic_summary: record.fetch("diagnostic_summary"),
          infra_diagnostics: record.fetch("infra_diagnostics")
        )
      end

      def persisted_form
        {
          "task_ref" => task_ref,
          "run_ref" => run_ref,
          "phase" => phase.to_s,
          "outcome" => outcome.to_s,
          "review_target" => review_target.persisted_form,
          "source_descriptor" => source_descriptor.persisted_form,
          "scope_snapshot" => scope_snapshot.persisted_form,
          "artifact_owner" => artifact_owner.persisted_form,
          "expected_state" => expected_state,
          "observed_state" => observed_state,
          "failing_command" => failing_command,
          "diagnostic_summary" => diagnostic_summary,
          "infra_diagnostics" => infra_diagnostics
        }
      end

      def error_category
        ErrorCategoryPolicy.blocked_error_category(
          phase: phase,
          diagnostic_summary: diagnostic_summary,
          observed_state: observed_state,
          failing_command: failing_command,
          infra_diagnostics: infra_diagnostics
        )
      end

      def remediation_summary
        ErrorCategoryPolicy.blocked_remediation(error_category)
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_ref == task_ref &&
          other.run_ref == run_ref &&
          other.phase == phase &&
          other.outcome == outcome &&
          other.review_target == review_target &&
          other.source_descriptor == source_descriptor &&
          other.scope_snapshot == scope_snapshot &&
          other.artifact_owner == artifact_owner &&
          other.expected_state == expected_state &&
          other.observed_state == observed_state &&
          other.failing_command == failing_command &&
          other.diagnostic_summary == diagnostic_summary &&
          other.infra_diagnostics == infra_diagnostics
      end
      alias eql? ==
    end
  end
end
