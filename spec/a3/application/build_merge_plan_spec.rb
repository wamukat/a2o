# frozen_string_literal: true

RSpec.describe A3::Application::BuildMergePlan do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }

  it "builds a persisted merge plan from task, run and project context" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      project_key: "a2o",
      kind: :child,
      edit_scope: [:repo_alpha],
      parent_ref: "A3-v2#3022"
    )
    run = A3::Domain::Run.new(
      ref: "run-1",
      project_key: "a2o",
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
    context = A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only,
        target_ref: "refs/heads/live"
      )
    )
    task_repository.save(task)
    run_repository.save(run)

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: context)

    expect(result.merge_plan.integration_target.target_ref).to eq("refs/heads/a2o/parent/A3-v2-3022")
    expect(result.merge_plan.integration_target.bootstrap_ref).to eq("refs/heads/live")
    expect(result.merge_plan.merge_policy).to eq(:ff_only)
    expect(result.merge_plan.merge_slots).to eq([:repo_alpha])
    expect(result.merge_plan.project_key).to eq("a2o")
  end
end
