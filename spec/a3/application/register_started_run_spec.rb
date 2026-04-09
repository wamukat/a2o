# frozen_string_literal: true

RSpec.describe A3::Application::RegisterStartedRun do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      publish_external_task_status: status_publisher,
      publish_external_task_activity: activity_publisher
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:status_publisher) { instance_double("ExternalTaskStatusPublisher", publish: nil) }
  let(:activity_publisher) { instance_double("ExternalTaskActivityPublisher", publish: nil) }

  it "persists a started implementation run and updates the task" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      external_task_id: 3025
    )
    task_repository.save(task)

    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
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
        snapshot_version: "snap-1"
      )
    )

    result = use_case.call(task_ref: task.ref, run: run)

    expect(run_repository.fetch("run-1")).to eq(run)
    expect(result.task.status).to eq(:in_progress)
    expect(result.task.current_run_ref).to eq("run-1")
    expect(status_publisher).to have_received(:publish).with(task_ref: "A3-v2#3025", external_task_id: 3025, status: :in_progress)
    expect(activity_publisher).to have_received(:publish).with(
      task_ref: "A3-v2#3025",
      external_task_id: 3025,
      body: /A3-v2 実行開始: implementation/
    )
  end

  it "marks a review run as in_review" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: [:repo_beta, :repo_alpha],
      external_task_id: 3022
    )
    task_repository.save(task)

    run = A3::Domain::Run.new(
      ref: "run-2",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/3022",
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
        snapshot_version: "snap-1"
      )
    )

    result = use_case.call(task_ref: task.ref, run: run)

    expect(result.task.status).to eq(:in_review)
    expect(result.task.current_run_ref).to eq("run-2")
    expect(status_publisher).to have_received(:publish).with(task_ref: "A3-v2#3022", external_task_id: 3022, status: :in_review)
    expect(activity_publisher).to have_received(:publish).with(
      task_ref: "A3-v2#3022",
      external_task_id: 3022,
      body: /A3-v2 実行開始: review/
    )
  end
end
