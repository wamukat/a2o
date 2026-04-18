# frozen_string_literal: true

RSpec.describe A3::Application::ReconcileManualMergeRecovery do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: A3::Application::PlanNextPhase.new,
      publish_external_task_status: status_publisher,
      publish_external_task_activity: activity_publisher
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:status_publisher) { instance_double(A3::Infra::NullExternalTaskStatusPublisher, publish: nil) }
  let(:activity_publisher) { instance_double(A3::Infra::NullExternalTaskActivityPublisher, publish: nil) }
  let(:artifact_owner) { A3::Domain::ArtifactOwner.new(owner_ref: "Sample#245", owner_scope: :task, snapshot_version: "merge-head") }
  let(:merge_run) do
    A3::Domain::Run.new(
      ref: "run-merge-245",
      task_ref: "Sample#245",
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
      artifact_owner: artifact_owner
    ).append_phase_evidence(
      phase: :merge,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "merge conflict requires recovery",
        observed_state: "merge_recovery_candidate",
        diagnostics: {
          "merge_recovery" => {
            "status" => "candidate",
            "source_ref" => "refs/heads/a2o/work/Sample-245",
            "merge_before_head" => "before123"
          },
          "merge_recovery_required" => true
        }
      )
    ).complete(outcome: :retryable)
  end

  it "records manual recovery evidence and returns the task to verification" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "Sample#245",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :merging,
        current_run_ref: nil,
        external_task_id: 245
      )
    )
    run_repository.save(merge_run)

    expect(status_publisher).to receive(:publish).with(task_ref: "Sample#245", external_task_id: 245, status: :verifying, task_kind: :single)
    expect(activity_publisher).to receive(:publish).with(
      task_ref: "Sample#245",
      external_task_id: 245,
      body: a_string_matching(/manual merge recovery reconciled.*merge_recovery: manual_reconciled.*merge_recovery_target: refs\/heads\/main.*merge_recovery_publish: before123\.\.after456/m)
    )

    result = use_case.call(
      task_ref: "Sample#245",
      run_ref: "run-merge-245",
      target_ref: "refs/heads/main",
      publish_after_head: "after456"
    )

    expect(result.task.status).to eq(:verifying)
    expect(result.task.verification_source_ref).to eq("refs/heads/main")
    expect(result.run.terminal_outcome).to eq(:verification_required)
    expect(result.run.phase_records.last.execution_record.diagnostics.fetch("merge_recovery")).to include(
      "status" => "manual_reconciled",
      "mode" => "manual",
      "source_ref" => "refs/heads/a2o/work/Sample-245",
      "publish_before_head" => "before123",
      "publish_after_head" => "after456",
      "previous_status" => "candidate"
    )
  end





  it "rejects terminal tasks even when the merge run is latest" do
    task_repository.save(
      A3::Domain::Task.new(ref: "Sample#245", kind: :single, edit_scope: [:repo_alpha], status: :done)
    )
    run_repository.save(merge_run)

    expect do
      use_case.call(task_ref: "Sample#245", run_ref: "run-merge-245", target_ref: "refs/heads/main")
    end.to raise_error(ArgumentError, /recoverable task status/)
  end

  it "rejects stale merge runs when a newer run exists for the task" do
    task_repository.save(
      A3::Domain::Task.new(ref: "Sample#245", kind: :single, edit_scope: [:repo_alpha], status: :blocked)
    )
    run_repository.save(merge_run)
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-verification-245",
        task_ref: "Sample#245",
        phase: :verification,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.runtime(task_ref: "Sample#245", ref: "refs/heads/main", source_type: :branch_head),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
        artifact_owner: artifact_owner
      )
    )

    expect do
      use_case.call(task_ref: "Sample#245", run_ref: "run-merge-245", target_ref: "refs/heads/main")
    end.to raise_error(ArgumentError, /latest task run/)
  end

  it "rejects merge runs without merge recovery evidence" do
    task_repository.save(
      A3::Domain::Task.new(ref: "Sample#245", kind: :single, edit_scope: [:repo_alpha], status: :blocked)
    )
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-merge-no-recovery",
        task_ref: "Sample#245",
        phase: :merge,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245"),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
        artifact_owner: artifact_owner
      ).complete(outcome: :blocked)
    )

    expect do
      use_case.call(task_ref: "Sample#245", run_ref: "run-merge-no-recovery", target_ref: "refs/heads/main")
    end.to raise_error(ArgumentError, /existing merge_recovery evidence/)
  end

  it "rejects non-merge runs" do
    task_repository.save(A3::Domain::Task.new(ref: "Sample#245", kind: :single, edit_scope: [:repo_alpha], status: :verifying))
    run_repository.save(
      A3::Domain::Run.new(
        ref: "run-verification-245",
        task_ref: "Sample#245",
        phase: :verification,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.runtime(task_ref: "Sample#245", ref: "refs/heads/a2o/work/Sample-245", source_type: :branch_head),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha], verification_scope: %i[repo_alpha], ownership_scope: :task),
        artifact_owner: artifact_owner
      )
    )

    expect do
      use_case.call(task_ref: "Sample#245", run_ref: "run-verification-245", target_ref: "refs/heads/main")
    end.to raise_error(ArgumentError, /requires a merge run/)
  end
end
