# frozen_string_literal: true

module A3
  module Application
    class HandleParentReviewDisposition
      Result = Struct.new(:terminal_status, :terminal_outcome, :blocked_diagnosis, :follow_up_child_refs, :follow_up_child_fingerprints, :comment_lines, keyword_init: true)

      def initialize(follow_up_child_writer:)
        @follow_up_child_writer = follow_up_child_writer
      end

      def call(task:, run:, disposition:)
        unless disposition.is_a?(A3::Domain::ReviewDisposition)
          return blocked_result(
            task: task,
            run: run,
            disposition_repo_scope: :invalid,
            summary: "parent review disposition is missing or invalid"
          )
        end

        return blocked_result(task: task, run: run, disposition_repo_scope: disposition.repo_scope, summary: disposition.summary) if disposition.blocked? || disposition.repo_scope == :unresolved

        return blocked_result(task: task, run: run, disposition_repo_scope: disposition.repo_scope, summary: "unsupported parent review disposition #{disposition.kind}") unless disposition.follow_up_child?

        write_result = @follow_up_child_writer.call(
          parent_task_ref: task.ref,
          parent_external_task_id: task.external_task_id,
          review_run_ref: run.ref,
          disposition: disposition
        )

        if write_result.success?
          Result.new(
            terminal_status: :todo,
            terminal_outcome: :follow_up_child,
            follow_up_child_refs: write_result.child_refs,
            follow_up_child_fingerprints: write_result.child_fingerprints,
            comment_lines: ["follow_up_children: #{write_result.child_refs.join(',')}"]
          )
        else
          blocked_result(task: task, run: run, disposition_repo_scope: disposition.repo_scope, summary: write_result.summary, diagnostics: write_result.diagnostics)
        end
      end

      private

      def blocked_result(task:, run:, disposition_repo_scope:, summary:, diagnostics: {})
        Result.new(
          terminal_status: :blocked,
          terminal_outcome: :blocked,
          blocked_diagnosis: A3::Domain::BlockedDiagnosis.new(
            task_ref: task.ref,
            run_ref: run.ref,
            phase: run.phase,
            outcome: :blocked,
            review_target: run.evidence.review_target,
            source_descriptor: run.evidence.source_descriptor,
            scope_snapshot: run.evidence.scope_snapshot,
            artifact_owner: run.evidence.artifact_owner,
            expected_state: "parent review disposition is handled canonically",
            observed_state: disposition_repo_scope.to_s,
            failing_command: "parent_review_disposition",
            diagnostic_summary: summary,
            infra_diagnostics: diagnostics
          )
        )
      end
    end
  end
end
