# frozen_string_literal: true

require "a3/domain/upstream_line_guard"

RSpec.describe A3::Domain::UpstreamLineGuard do
  Snapshot = Struct.new(:ref, :head, keyword_init: true)

  let(:resolver) { instance_double("InheritedParentStateResolver") }
  subject(:guard) { described_class.new(inherited_parent_state_resolver: resolver) }

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3030",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :todo,
      parent_ref: "A3-v2#3022"
    )
  end

  let(:blocked_sibling) do
    A3::Domain::Task.new(
      ref: "A3-v2#3031",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta],
      status: :blocked,
      parent_ref: "A3-v2#3022"
    )
  end

  let(:healthy_sibling) do
    A3::Domain::Task.new(
      ref: "A3-v2#3032",
      kind: :child,
      edit_scope: [:repo_gamma],
      verification_scope: [:repo_gamma],
      status: :done,
      parent_ref: "A3-v2#3022"
    )
  end

  let(:current_snapshot) do
    Snapshot.new(
      ref: "refs/heads/a2o/parent/A3-v2-3022",
      head: "parent-head-1"
    )
  end

  let(:verification_blocked_run) do
    A3::Domain::Run.new(
      ref: "run-3031",
      task_ref: blocked_sibling.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(
        task_ref: blocked_sibling.ref,
        ref: current_snapshot.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: blocked_sibling.ref,
        run_ref: "run-3031",
        phase: :verification,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: blocked_sibling.ref,
          phase_ref: :verification
        ),
        source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(
          task_ref: blocked_sibling.ref,
          ref: current_snapshot.ref
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.parent_ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
        ),
        expected_state: "verification succeeds",
        observed_state: "lint failed on inherited parent line",
        failing_command: "commands/verify-all",
        diagnostic_summary: "verification failed",
        infra_diagnostics: {}
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "verification failed",
        diagnostics: {
          "inherited_parent_ref" => current_snapshot.ref,
          "inherited_parent_head" => current_snapshot.head
        }
      )
    )
  end

  before do
    allow(resolver).to receive(:snapshot_for).and_return(current_snapshot)
  end

  it "holds child implementation when a sibling is blocked on verification for the same inherited parent head" do
    assessment = guard.evaluate(
      task: task,
      phase: :implementation,
      tasks: [task, blocked_sibling, healthy_sibling],
      runs: [verification_blocked_run]
    )

    expect(assessment.healthy?).to eq(false)
    expect(assessment.reason).to eq(:upstream_unhealthy)
    expect(assessment.blocking_task_refs).to eq([blocked_sibling.ref])
  end

  it "holds ordinary child verification against the same inherited parent head" do
    verifying_task = A3::Domain::Task.new(
      ref: task.ref,
      kind: :child,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      status: :verifying,
      parent_ref: task.parent_ref
    )

    assessment = guard.evaluate(
      task: verifying_task,
      phase: :verification,
      tasks: [verifying_task, blocked_sibling, healthy_sibling],
      runs: [verification_blocked_run]
    )

    expect(assessment.healthy?).to eq(false)
    expect(assessment.blocking_task_refs).to eq([blocked_sibling.ref])
  end

  it "does not hold child work for non-verification sibling failures" do
    executor_failed_run = A3::Domain::Run.new(
      ref: "run-3031-exec",
      task_ref: blocked_sibling.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(
        task_ref: blocked_sibling.ref,
        ref: "refs/heads/a2o/work/A3-v2-3031"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: blocked_sibling.ref,
        run_ref: "run-3031-exec",
        phase: :implementation,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: blocked_sibling.ref,
          phase_ref: :implementation
        ),
        source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(
          task_ref: blocked_sibling.ref,
          ref: "refs/heads/a2o/work/A3-v2-3031"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: [:repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.parent_ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
        ),
        expected_state: "executor succeeds",
        observed_state: "missing token",
        failing_command: "codex exec --json -",
        diagnostic_summary: "executor failed",
        infra_diagnostics: {}
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "executor failed",
        diagnostics: {
          "inherited_parent_ref" => current_snapshot.ref,
          "inherited_parent_head" => current_snapshot.head
        }
      )
    )

    assessment = guard.evaluate(
      task: task,
      phase: :implementation,
      tasks: [task, blocked_sibling, healthy_sibling],
      runs: [executor_failed_run]
    )

    expect(assessment.healthy?).to eq(true)
    expect(assessment.blocking_task_refs).to eq([])
  end

  it "does not hold child work when the current inherited parent head has advanced" do
    allow(resolver).to receive(:snapshot_for).and_return(
      Snapshot.new(ref: current_snapshot.ref, head: "parent-head-2")
    )

    assessment = guard.evaluate(
      task: task,
      phase: :implementation,
      tasks: [task, blocked_sibling, healthy_sibling],
      runs: [verification_blocked_run]
    )

    expect(assessment.healthy?).to eq(true)
    expect(assessment.blocking_task_refs).to eq([])
  end

  it "does not hold merge-recovery verification when there is no inherited parent snapshot" do
    verifying_task = A3::Domain::Task.new(
      ref: task.ref,
      kind: :child,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      status: :verifying,
      parent_ref: task.parent_ref,
      verification_source_ref: "refs/heads/main"
    )
    allow(resolver).to receive(:snapshot_for).with(task: verifying_task, phase: :verification).and_return(nil)

    assessment = guard.evaluate(
      task: verifying_task,
      phase: :verification,
      tasks: [verifying_task, blocked_sibling, healthy_sibling],
      runs: [verification_blocked_run]
    )

    expect(assessment.healthy?).to eq(true)
    expect(assessment.blocking_task_refs).to eq([])
  end
end
