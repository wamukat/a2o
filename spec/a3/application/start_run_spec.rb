# frozen_string_literal: true

RSpec.describe A3::Application::StartRun do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:start_phase) { A3::Application::StartPhase.new(run_id_generator: -> { "run-1" }) }
  let(:register_started_run) do
    A3::Application::RegisterStartedRun.new(
      task_repository: task_repository,
      run_repository: run_repository
    )
  end
  let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }
  let(:prepared_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha"
      }
    )
  end

  subject(:use_case) do
    described_class.new(
      start_phase: start_phase,
      register_started_run: register_started_run,
      task_repository: task_repository,
      prepare_workspace: prepare_workspace
    )
  end

  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/A3-v2-3025",
      task_ref: "A3-v2#3025"
    )
  end

  let(:scope_snapshot) do
    A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      ownership_scope: :task
    )
  end

  let(:review_target) do
    A3::Domain::ReviewTarget.new(
      base_commit: "base123",
      head_commit: "head456",
      task_ref: "A3-v2#3025",
      phase_ref: :review
    )
  end

  it "starts and persists an implementation run in one step" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    task_repository.save(task)
    expect(prepare_workspace).to receive(:call).with(
      task: task,
      phase: :implementation,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      artifact_owner: an_instance_of(A3::Domain::ArtifactOwner),
      bootstrap_marker: "workspace-hook:v1"
    ).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )

    result = use_case.call(
      task_ref: task.ref,
      phase: :implementation,
      source_descriptor: source_descriptor,
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      bootstrap_marker: "workspace-hook:v1"
    )

    expect(result.run.ref).to eq("run-1")
    expect(result.run.phase).to eq(:implementation)
    expect(result.task.current_run_ref).to eq("run-1")
    expect(result.task.status).to eq(:in_progress)
    expect(result.workspace).to eq(prepared_workspace)
    expect(run_repository.fetch("run-1")).to eq(result.run)
  end

  it "starts and persists a review run with in_review status" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha]
    )
    runtime_source_descriptor = A3::Domain::SourceDescriptor.new(
      workspace_kind: :runtime_workspace,
      source_type: :integration_record,
      ref: "refs/heads/a3/parent/A3-v2-3022",
      task_ref: task.ref
    )
    runtime_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace",
      source_descriptor: runtime_source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-alpha"
      }
    )
    task_repository.save(task)
    expect(prepare_workspace).to receive(:call).with(
      task: task,
      phase: :review,
      source_descriptor: an_instance_of(A3::Domain::SourceDescriptor),
      scope_snapshot: an_instance_of(A3::Domain::ScopeSnapshot),
      artifact_owner: an_instance_of(A3::Domain::ArtifactOwner),
      bootstrap_marker: "workspace-hook:v2"
    ).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: runtime_workspace)
    )

    result = use_case.call(
      task_ref: task.ref,
      phase: :review,
      source_descriptor: runtime_source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta, :repo_alpha],
        verification_scope: [:repo_beta, :repo_alpha],
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
      ),
      bootstrap_marker: "workspace-hook:v2"
    )

    expect(result.task.status).to eq(:in_review)
    expect(result.run.phase).to eq(:review)
    expect(result.workspace).to eq(runtime_workspace)
  end

  it "rejects a prepared workspace that does not match the started run source descriptor" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha]
    )
    task_repository.save(task)
    mismatched_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace",
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head999",
        task_ref: task.ref
      ),
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-alpha"
      }
    )

    expect(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: mismatched_workspace)
    )

    expect do
      use_case.call(
        task_ref: task.ref,
        phase: :review,
      source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: "refs/heads/a3/parent/A3-v2-3022",
          task_ref: task.ref
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta, :repo_alpha],
          verification_scope: [:repo_beta, :repo_alpha],
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
        ),
        bootstrap_marker: "workspace-hook:v2"
      )
    end.to raise_error(
      A3::Domain::ConfigurationError,
      /prepared workspace source descriptor does not match started run source descriptor/
    )
    expect(task_repository.fetch(task.ref).current_run_ref).to be_nil
    expect { run_repository.fetch("run-1") }.to raise_error(A3::Domain::RecordNotFound)
  end
end
