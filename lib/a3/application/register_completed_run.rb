# frozen_string_literal: true

module A3
  module Application
    class RegisterCompletedRun
      Result = Struct.new(:task, :run, keyword_init: true)

      def initialize(task_repository:, run_repository:, plan_next_phase:, publish_external_task_status: nil, publish_external_task_activity: nil, integration_ref_readiness_checker:, handle_parent_review_disposition: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @plan_next_phase = plan_next_phase
        @publish_external_task_status = publish_external_task_status
        @publish_external_task_activity = publish_external_task_activity
        raise ArgumentError, "integration_ref_readiness_checker is required" unless integration_ref_readiness_checker

        @integration_ref_readiness_checker = integration_ref_readiness_checker
        @handle_parent_review_disposition = handle_parent_review_disposition
      end

      def call(task_ref:, run_ref:, outcome:, execution: nil)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        disposition_result = resolve_parent_review_disposition(task: task, run: run, execution: execution, outcome: outcome)
        return disposition_result if disposition_result

        artifact_violation = artifact_contract_violation?(task: task, run: run, outcome: outcome)
        terminal_outcome = artifact_violation ? :blocked : outcome
        phase_result = @plan_next_phase.call(task: task, run: run, outcome: terminal_outcome)
        completed_run = completed_run_for(task: task, run: run, outcome: terminal_outcome, artifact_violation: artifact_violation)
        completed_task = task.complete_run(
          next_phase: phase_result.next_phase,
          terminal_status: phase_result.terminal_status
        )

        @run_repository.save(completed_run)
        @task_repository.save(completed_task)
        @publish_external_task_status&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          status: completed_task.status,
          task_kind: completed_task.kind
        )
        @publish_external_task_activity&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          body: completed_run_comment(run: completed_run, task: completed_task)
        )

        Result.new(task: completed_task, run: completed_run)
      end

      private

      def resolve_parent_review_disposition(task:, run:, execution:, outcome:)
        return nil unless task.kind == :parent
        return nil unless run.phase.to_sym == :review
        return nil if outcome.to_sym == :completed

        unless @handle_parent_review_disposition
          return finalize_parent_review_disposition(
            task: task,
            run: run,
            result: A3::Application::HandleParentReviewDisposition::Result.new(
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
                expected_state: "parent review disposition handler is available",
                observed_state: "missing handler",
                failing_command: "parent_review_disposition",
                diagnostic_summary: "parent review disposition handler is missing",
                infra_diagnostics: {}
              )
            )
          )
        end

        disposition_result = @handle_parent_review_disposition.call(
          task: task,
          run: run,
          disposition: execution&.review_disposition
        )
        finalize_parent_review_disposition(task: task, run: run, result: disposition_result)
      end

      def finalize_parent_review_disposition(task:, run:, result:)
        last_phase_record = latest_phase_record(run)
        execution_record = last_phase_record&.execution_record
        completed_run =
          if result.blocked_diagnosis
            run.append_blocked_diagnosis(result.blocked_diagnosis, execution_record: execution_record).complete(outcome: result.terminal_outcome)
          else
            enriched_run = enrich_follow_up_child_evidence(run, child_fingerprints: result.follow_up_child_fingerprints)
            enriched_run.complete(outcome: result.terminal_outcome)
          end
        completed_task = task.complete_run(next_phase: nil, terminal_status: result.terminal_status)

        @run_repository.save(completed_run)
        @task_repository.save(completed_task)
        @publish_external_task_status&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          status: completed_task.status,
          task_kind: completed_task.kind
        )
        body = completed_run_comment(run: completed_run, task: completed_task, extra_lines: result.comment_lines)
        @publish_external_task_activity&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          body: body
        )
        Result.new(task: completed_task, run: completed_run)
      end

      def enrich_follow_up_child_evidence(run, child_fingerprints:)
        last_phase_record = run.phase_records.last
        execution_record = last_phase_record&.execution_record
        return run if execution_record.nil?

        updated_execution_record = execution_record.with_follow_up_child_fingerprints(Array(child_fingerprints))
        run.replace_latest_phase_record(last_phase_record.with_execution_record(updated_execution_record))
      end

      def completed_run_for(task:, run:, outcome:, artifact_violation:)
        return run.complete(outcome: outcome) unless artifact_violation

        run.append_blocked_diagnosis(
          artifact_contract_blocked_diagnosis(task: task, run: run)
        ).complete(outcome: :blocked)
      end

      def artifact_contract_violation?(task:, run:, outcome:)
        return false unless outcome.to_sym == :completed
        return false unless task.kind == :child
        return false unless run.phase.to_sym == :merge
        return false unless task.parent_ref

        !@integration_ref_readiness_checker.check(
          ref: parent_integration_ref_for(task),
          repo_slots: task.edit_scope
        ).ready?
      end

      def artifact_contract_blocked_diagnosis(task:, run:)
        readiness = @integration_ref_readiness_checker.check(
          ref: parent_integration_ref_for(task),
          repo_slots: task.edit_scope
        )
        A3::Domain::BlockedDiagnosis.new(
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          outcome: :blocked,
          review_target: run.evidence.review_target,
          source_descriptor: run.source_descriptor,
          scope_snapshot: run.scope_snapshot,
          artifact_owner: run.artifact_owner,
          expected_state: "parent integration ref is available across all edit scope slots",
          observed_state: readiness.diagnostic_summary,
          failing_command: "integration_ref_readiness_check",
          diagnostic_summary: readiness.diagnostic_summary,
          infra_diagnostics: { "missing_slots" => readiness.missing_slots.map(&:to_s), "ref" => readiness.ref }
        )
      end

      def parent_integration_ref_for(task)
        "refs/heads/a3/parent/#{task.parent_ref.tr('#', '-')}"
      end

      def completed_run_comment(run:, task:, extra_lines: nil)
        lines = [
          "A3 実行完了: #{run.phase}",
          "run_ref: #{run.ref}",
          "結果: #{run.terminal_outcome}",
          "タスク状態: #{task.status}"
        ]

        phase_record = latest_phase_record(run)
        execution_record = phase_record&.execution_record
        blocked_diagnosis = phase_record&.blocked_diagnosis

        if execution_record&.summary && !execution_record.summary.empty?
          lines << "要約: #{single_line(execution_record.summary)}"
        end

        if blocked_diagnosis
          lines << "ブロック要約: #{single_line(blocked_diagnosis.diagnostic_summary)}"
          lines << "失敗コマンド: #{single_line(blocked_diagnosis.failing_command)}" if present?(blocked_diagnosis.failing_command)
          lines << "観測状態: #{single_line(blocked_diagnosis.observed_state)}" if present?(blocked_diagnosis.observed_state)
        elsif execution_record&.failing_command
          lines << "失敗コマンド: #{single_line(execution_record.failing_command)}"
          lines << "観測状態: #{single_line(execution_record.observed_state)}" if present?(execution_record.observed_state)
        end
        Array(extra_lines).each { |line| lines << line }

        lines.join("\n")
      end

      def latest_phase_record(run)
        run.phase_records.reverse_each.find { |record| record.phase == run.phase }
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def single_line(text)
        text.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")
      end
    end
  end
end
