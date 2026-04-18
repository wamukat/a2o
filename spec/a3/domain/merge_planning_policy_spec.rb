# frozen_string_literal: true

RSpec.describe A3::Domain::MergePlanningPolicy do
  subject(:policy) { described_class.new }

  it "builds a merge-to-parent plan for child tasks" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "A3-v2#3022"
    )
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_parent, policy: :ff_only, target_ref: "refs/heads/live")

    plan = policy.build(task: task, run: run, merge_config: merge_config)

    expect(plan.task_ref).to eq(task.ref)
    expect(plan.run_ref).to eq(run.ref)
    expect(plan.merge_source.source_ref).to eq("refs/heads/a2o/work/3025")
    expect(plan.integration_target.target_ref).to eq("refs/heads/a2o/parent/A3-v2-3022")
    expect(plan.integration_target.bootstrap_ref).to eq("refs/heads/live")
    expect(plan.merge_policy).to eq(:ff_only)
    expect(plan.merge_slots).to eq([:repo_alpha])
  end

  it "uses project-configured live target as bootstrap ref for merge_to_parent" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "A3-v2#3022"
    )
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(
      target: :merge_to_parent,
      policy: :ff_only,
      target_ref: "refs/heads/feature/prototype"
    )

    plan = policy.build(task: task, run: run, merge_config: merge_config)

    expect(plan.integration_target.target_ref).to eq("refs/heads/a2o/parent/A3-v2-3022")
    expect(plan.integration_target.bootstrap_ref).to eq("refs/heads/feature/prototype")
  end

  it "namespaces merge-to-parent refs when a runtime branch namespace is configured" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "A3-v2#3022"
    )
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/runtime/a3-test/work/A3-v2-3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_parent, policy: :ff_only, target_ref: "refs/heads/live")

    plan = described_class.new(branch_namespace: "runtime/a3-test").build(task: task, run: run, merge_config: merge_config)

    expect(plan.integration_target.target_ref).to eq("refs/heads/a2o/runtime/a3-test/parent/A3-v2-3022")
  end

  it "builds a merge-to-live plan for parent tasks" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_alpha, :repo_beta]
    )
    run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2#3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha, :repo_beta],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :no_ff, target_ref: "refs/heads/feature/prototype")

    plan = policy.build(task: task, run: run, merge_config: merge_config)

    expect(plan.integration_target.target_ref).to eq("refs/heads/feature/prototype")
    expect(plan.merge_source.source_ref).to eq("refs/heads/a2o/parent/A3-v2#3022")
    expect(plan.merge_policy).to eq(:no_ff)
    expect(plan.merge_slots).to eq(%i[repo_alpha repo_beta])
  end

  it "rejects merge_to_parent for a task without parent topology" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :single,
      edit_scope: [:repo_alpha]
    )
    run = A3::Domain::Run.new(
      ref: "run-3",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_parent, policy: :ff_only, target_ref: "refs/heads/live")

    expect { policy.build(task: task, run: run, merge_config: merge_config) }
      .to raise_error(A3::Domain::ConfigurationError)
  end

  it "rejects merge_to_live for child tasks" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "A3-v2#3022"
    )
    run = A3::Domain::Run.new(
      ref: "run-4",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :no_ff, target_ref: "refs/heads/feature/prototype")

    expect { policy.build(task: task, run: run, merge_config: merge_config) }
      .to raise_error(A3::Domain::ConfigurationError)
  end

  it "rejects merge_to_live without an explicit target ref" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_alpha]
    )
    run = A3::Domain::Run.new(
      ref: "run-5",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2#3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :merge
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :ff_only, target_ref: nil)

    expect { policy.build(task: task, run: run, merge_config: merge_config) }
      .to raise_error(A3::Domain::ConfigurationError, /requires explicit target_ref/)
  end

  it "rejects merge_to_live with a blank target ref" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_alpha]
    )
    run = A3::Domain::Run.new(
      ref: "run-6",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2#3022",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :merge
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :parent,
        snapshot_version: "head456"
      )
    )
    merge_config = A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :ff_only, target_ref: "   ")

    expect { policy.build(task: task, run: run, merge_config: merge_config) }
      .to raise_error(A3::Domain::ConfigurationError, /requires explicit target_ref/)
  end
end
