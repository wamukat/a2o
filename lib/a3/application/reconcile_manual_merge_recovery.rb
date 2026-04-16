# frozen_string_literal: true

module A3
  module Application
    class ReconcileManualMergeRecovery
      Result = Struct.new(:task, :run, :recovery, keyword_init: true)

      def initialize(task_repository:, run_repository:, plan_next_phase:, publish_external_task_status: nil, publish_external_task_activity: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @plan_next_phase = plan_next_phase
        @publish_external_task_status = publish_external_task_status
        @publish_external_task_activity = publish_external_task_activity
      end

      def call(task_ref:, run_ref:, target_ref:, source_ref: nil, publish_before_head: nil, publish_after_head: nil, summary: nil)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        validate_request!(task: task, run: run, target_ref: target_ref)

        recovery = manual_recovery_record(
          run: run,
          target_ref: target_ref,
          source_ref: source_ref,
          publish_before_head: publish_before_head,
          publish_after_head: publish_after_head
        )
        reconciled_run = append_manual_recovery_evidence(run: run, recovery: recovery, summary: summary).complete(outcome: :verification_required)
        phase_result = @plan_next_phase.call(task: task, run: run, outcome: :verification_required)
        reconciled_task = task.complete_run(
          next_phase: phase_result.next_phase,
          terminal_status: phase_result.terminal_status,
          verification_source_ref: normalized_required_ref(target_ref, "target_ref")
        )

        @run_repository.save(reconciled_run)
        @task_repository.save(reconciled_task)
        @publish_external_task_status&.publish(
          task_ref: reconciled_task.ref,
          external_task_id: reconciled_task.external_task_id,
          status: reconciled_task.status,
          task_kind: reconciled_task.kind
        )
        @publish_external_task_activity&.publish(
          task_ref: reconciled_task.ref,
          external_task_id: reconciled_task.external_task_id,
          body: reconciled_comment(run: reconciled_run, task: reconciled_task, recovery: recovery)
        )

        Result.new(task: reconciled_task, run: reconciled_run, recovery: recovery)
      end

      private

      def validate_request!(task:, run:, target_ref:)
        raise ArgumentError, "run #{run.ref} belongs to #{run.task_ref}, not #{task.ref}" unless run.task_ref == task.ref
        raise ArgumentError, "manual merge recovery reconcile requires a merge run" unless run.phase.to_sym == :merge
        unless %i[merging blocked].include?(task.status.to_sym)
          raise ArgumentError, "manual merge recovery reconcile requires a recoverable task status, got #{task.status}"
        end
        if task.current_run_ref && task.current_run_ref != run.ref
          raise ArgumentError, "task #{task.ref} is currently bound to #{task.current_run_ref}, not #{run.ref}"
        end
        raise ArgumentError, "manual merge recovery reconcile requires the latest task run" unless latest_run_for(task)&.ref == run.ref

        normalized_required_ref(target_ref, "target_ref")
        validate_recoverable_candidate!(run)
      end

      def latest_run_for(task)
        @run_repository.all.select { |candidate| candidate.task_ref == task.ref }.last
      end

      def validate_recoverable_candidate!(run)
        candidate = latest_merge_recovery(run)
        raise ArgumentError, "manual merge recovery reconcile requires existing merge_recovery evidence" unless candidate
        if %w[recovered manual_reconciled].include?(candidate["status"].to_s)
          raise ArgumentError, "merge_recovery evidence is already resolved: #{candidate['status']}"
        end
      end

      def append_manual_recovery_evidence(run:, recovery:, summary:)
        run.append_phase_evidence(
          phase: run.phase,
          source_descriptor: run.source_descriptor,
          scope_snapshot: run.scope_snapshot,
          execution_record: A3::Domain::PhaseExecutionRecord.new(
            summary: normalized_optional(summary) || "manual merge recovery reconciled",
            observed_state: "merge_recovery_manual_reconciled",
            diagnostics: {
              "merge_recovery" => recovery,
              "merge_recovery_required" => false,
              "merge_recovery_verification_required" => true,
              "merge_recovery_verification_source_ref" => recovery.fetch("target_ref")
            }
          )
        )
      end

      def manual_recovery_record(run:, target_ref:, source_ref:, publish_before_head:, publish_after_head:)
        candidate = latest_merge_recovery(run)
        normalized_target_ref = normalized_required_ref(target_ref, "target_ref")
        candidate_target_ref = candidate&.fetch("target_ref", nil)
        if candidate_target_ref && candidate_target_ref != normalized_target_ref
          raise ArgumentError, "target_ref does not match merge recovery candidate: #{normalized_target_ref} != #{candidate_target_ref}"
        end

        {
          "status" => "manual_reconciled",
          "mode" => "manual",
          "target_ref" => normalized_target_ref,
          "source_ref" => normalized_optional(source_ref) || candidate&.fetch("source_ref", nil),
          "publish_before_head" => normalized_optional(publish_before_head) || candidate&.fetch("publish_before_head", nil) || candidate&.fetch("merge_before_head", nil),
          "publish_after_head" => normalized_optional(publish_after_head),
          "previous_status" => candidate&.fetch("status", nil)
        }.reject { |_, value| value.nil? || value.to_s.empty? }
      end

      def latest_merge_recovery(run)
        run.phase_records.reverse_each do |record|
          recovery = record.execution_record&.diagnostics&.fetch("merge_recovery", nil)
          return recovery if recovery.is_a?(Hash)

          blocked_recovery = record.blocked_diagnosis&.infra_diagnostics&.fetch("merge_recovery", nil)
          return blocked_recovery if blocked_recovery.is_a?(Hash)
        end
        nil
      end

      def reconciled_comment(run:, task:, recovery:)
        lines = [
          "A3 manual merge recovery reconciled: #{run.phase}",
          "run_ref: #{run.ref}",
          "結果: #{run.terminal_outcome}",
          "タスク状態: #{task.status}",
          "merge_recovery: #{recovery.fetch('status')}",
          "merge_recovery_target: #{recovery.fetch('target_ref')}"
        ]
        lines << "merge_recovery_source: #{recovery.fetch('source_ref')}" if recovery["source_ref"]
        if recovery["publish_before_head"] || recovery["publish_after_head"]
          lines << "merge_recovery_publish: #{recovery['publish_before_head']}..#{recovery['publish_after_head']}"
        end
        lines.join("\n")
      end

      def normalized_required_ref(value, name)
        normalized = normalized_optional(value)
        raise ArgumentError, "#{name} is required" unless normalized
        raise ArgumentError, "#{name} must be a branch ref: #{normalized}" unless normalized.start_with?("refs/heads/")

        normalized
      end

      def normalized_optional(value)
        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized
      end
    end
  end
end
