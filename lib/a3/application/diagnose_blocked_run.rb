# frozen_string_literal: true

module A3
  module Application
    class DiagnoseBlockedRun
      Result = Struct.new(:task, :run, :diagnosis, keyword_init: true)

      def initialize(task_repository:, run_repository:)
        @task_repository = task_repository
        @run_repository = run_repository
      end

      def call(task_ref:, run_ref:, expected_state:, observed_state:, failing_command:, diagnostic_summary:, infra_diagnostics: {})
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        ensure_blocked_run!(run)
        diagnosis = A3::Domain::BlockedDiagnosis.new(
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          outcome: run.terminal_outcome || :blocked,
          review_target: run.evidence.review_target,
          source_descriptor: run.evidence.source_descriptor,
          scope_snapshot: run.evidence.scope_snapshot,
          artifact_owner: run.evidence.artifact_owner,
          expected_state: expected_state,
          observed_state: observed_state,
          failing_command: failing_command,
          diagnostic_summary: diagnostic_summary,
          infra_diagnostics: infra_diagnostics
        )

        updated_run = run.append_blocked_diagnosis(diagnosis)
        @run_repository.save(updated_run)

        Result.new(task: task, run: updated_run, diagnosis: diagnosis)
      end

      private

      def ensure_blocked_run!(run)
        return if run.terminal_outcome == :blocked

        raise A3::Domain::ConfigurationError, "blocked run required for diagnosis: #{run.ref}"
      end
    end

    class ShowBlockedDiagnosis
      Result = Struct.new(:task, :run, :diagnosis, :evidence_summary, :recovery, :worker_response_bundle, keyword_init: true)

      def initialize(task_repository:, run_repository:, plan_rerun:, build_scope_snapshot:, build_artifact_owner:)
        @task_repository = task_repository
        @run_repository = run_repository
        @resolve_run_recovery = ResolveRunRecovery.new(
          plan_rerun: plan_rerun,
          build_scope_snapshot: build_scope_snapshot,
          build_artifact_owner: build_artifact_owner
        )
      end

      def call(task_ref:, run_ref:, runtime_package:)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        blocked_phase_record = latest_blocked_phase_record(run)
        diagnosis = enrich_blocked_diagnosis(blocked_phase_record)
        evidence_summary = build_evidence_summary(run.evidence)
        worker_response_bundle = worker_response_bundle_for(blocked_phase_record)

        Result.new(
          task: task,
          run: run,
          diagnosis: diagnosis,
          evidence_summary: evidence_summary,
          recovery: @resolve_run_recovery.call(task: task, run: run, runtime_package: runtime_package).recovery,
          worker_response_bundle: worker_response_bundle
        ).freeze
      end

      private

      def latest_blocked_phase_record(run)
        phase_record = run.phase_records.reverse_each.find { |item| !item.blocked_diagnosis.nil? }
        return phase_record if phase_record

        raise A3::Domain::ConfigurationError, "blocked diagnosis not found for run #{run.ref}"
      end

      def enrich_blocked_diagnosis(phase_record)
        diagnosis = phase_record.blocked_diagnosis
        worker_response_bundle = worker_response_bundle_for(phase_record)
        return diagnosis unless worker_response_bundle

        diagnostics = diagnosis.infra_diagnostics.merge("worker_response_bundle" => worker_response_bundle)
        return diagnosis if diagnostics == diagnosis.infra_diagnostics

        A3::Domain::BlockedDiagnosis.new(
          task_ref: diagnosis.task_ref,
          run_ref: diagnosis.run_ref,
          phase: diagnosis.phase,
          outcome: diagnosis.outcome,
          review_target: diagnosis.review_target,
          source_descriptor: diagnosis.source_descriptor,
          scope_snapshot: diagnosis.scope_snapshot,
          artifact_owner: diagnosis.artifact_owner,
          expected_state: diagnosis.expected_state,
          observed_state: diagnosis.observed_state,
          failing_command: diagnosis.failing_command,
          diagnostic_summary: diagnosis.diagnostic_summary,
          infra_diagnostics: diagnostics
        )
      end

      def worker_response_bundle_for(phase_record)
        execution_record = phase_record.execution_record
        return nil unless execution_record

        diagnostics = execution_record.diagnostics
        diagnostics["worker_response_bundle"]
      end

      def build_evidence_summary(evidence)
        A3::Domain::OperatorInspectionReadModel::EvidenceSummary.from_evidence(evidence)
      end
    end
  end
end
