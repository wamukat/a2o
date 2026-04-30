# frozen_string_literal: true

require "a3/domain/deep_freezable"

module A3
  module Domain
    class PhaseExecutionRecord
      include DeepFreezable

      attr_reader :summary, :failing_command, :observed_state, :diagnostics, :runtime_snapshot, :review_disposition, :clarification_request, :skill_feedback, :docs_impact, :refactoring_assessment, :follow_up_child_fingerprints

      def initialize(summary:, failing_command: nil, observed_state: nil, diagnostics: {}, runtime_snapshot: nil, review_disposition: nil, clarification_request: nil, skill_feedback: [], docs_impact: nil, refactoring_assessment: nil, follow_up_child_fingerprints: [])
        @summary = summary
        @failing_command = failing_command
        @observed_state = observed_state
        @diagnostics = deep_freeze_value(diagnostics)
        @runtime_snapshot = runtime_snapshot
        @review_disposition = deep_freeze_value(review_disposition)
        @clarification_request = deep_freeze_value(clarification_request)
        @skill_feedback = deep_freeze_value(Array(skill_feedback))
        @docs_impact = deep_freeze_value(docs_impact)
        @refactoring_assessment = deep_freeze_value(refactoring_assessment)
        @follow_up_child_fingerprints = deep_freeze_value(Array(follow_up_child_fingerprints))
        freeze
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          summary: record.fetch("summary"),
          failing_command: record["failing_command"],
          observed_state: record["observed_state"],
          diagnostics: record.fetch("diagnostics", {}),
          runtime_snapshot: PhaseRuntimeSnapshot.from_persisted_form(record["runtime_snapshot"]),
          review_disposition: record["review_disposition"],
          clarification_request: record["clarification_request"],
          skill_feedback: record.fetch("skill_feedback", []),
          docs_impact: record["docs_impact"],
          refactoring_assessment: record["refactoring_assessment"],
          follow_up_child_fingerprints: record.fetch("follow_up_child_fingerprints", [])
        )
      end

      def self.from_execution_result(execution, runtime_snapshot: nil)
        new(
          summary: execution.summary,
          failing_command: execution.failing_command,
          observed_state: execution.observed_state,
          diagnostics: execution.diagnostics,
          runtime_snapshot: runtime_snapshot,
          review_disposition: execution.review_disposition && {
            "kind" => execution.review_disposition.kind.to_s,
            "slot_scopes" => execution.review_disposition.slot_scopes.map(&:to_s),
            "summary" => execution.review_disposition.summary,
            "description" => execution.review_disposition.description,
            "finding_key" => execution.review_disposition.finding_key
          },
          clarification_request: execution.clarification_request&.persisted_form,
          skill_feedback: execution.skill_feedback,
          docs_impact: execution.docs_impact,
          refactoring_assessment: execution.refactoring_assessment
        )
      end

      def with_follow_up_child_fingerprints(fingerprints)
        self.class.new(
          summary: summary,
          failing_command: failing_command,
          observed_state: observed_state,
          diagnostics: diagnostics,
          runtime_snapshot: runtime_snapshot,
          review_disposition: review_disposition,
          clarification_request: clarification_request,
          skill_feedback: skill_feedback,
          docs_impact: docs_impact,
          refactoring_assessment: refactoring_assessment,
          follow_up_child_fingerprints: fingerprints
        )
      end

      def with_diagnostics(value)
        self.class.new(
          summary: summary,
          failing_command: failing_command,
          observed_state: observed_state,
          diagnostics: value,
          runtime_snapshot: runtime_snapshot,
          review_disposition: review_disposition,
          clarification_request: clarification_request,
          skill_feedback: skill_feedback,
          docs_impact: docs_impact,
          refactoring_assessment: refactoring_assessment,
          follow_up_child_fingerprints: follow_up_child_fingerprints
        )
      end

      def persisted_form
        {
          "summary" => summary,
          "failing_command" => failing_command,
          "observed_state" => observed_state,
          "diagnostics" => diagnostics,
          "runtime_snapshot" => runtime_snapshot&.persisted_form,
          "review_disposition" => review_disposition,
          "clarification_request" => clarification_request,
          "skill_feedback" => skill_feedback,
          "docs_impact" => docs_impact,
          "refactoring_assessment" => refactoring_assessment,
          "follow_up_child_fingerprints" => follow_up_child_fingerprints
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.summary == summary &&
          other.failing_command == failing_command &&
          other.observed_state == observed_state &&
          other.diagnostics == diagnostics &&
          other.runtime_snapshot == runtime_snapshot &&
          other.review_disposition == review_disposition &&
          other.clarification_request == clarification_request &&
          other.skill_feedback == skill_feedback &&
          other.docs_impact == docs_impact &&
          other.refactoring_assessment == refactoring_assessment &&
          other.follow_up_child_fingerprints == follow_up_child_fingerprints
      end
      alias eql? ==
    end
  end
end
