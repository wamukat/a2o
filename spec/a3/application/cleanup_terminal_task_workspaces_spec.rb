# frozen_string_literal: true

RSpec.describe A3::Application::CleanupTerminalTaskWorkspaces do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:provisioner) { instance_double(A3::Infra::LocalWorkspaceProvisioner) }

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      provisioner: provisioner
    )
  end

  it "cleans done terminal tasks by default" do
    done_task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done
    )
    blocked_task = A3::Domain::Task.new(
      ref: "A3-v2#3026",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :blocked
    )
    task_repository.save(done_task)
    task_repository.save(blocked_task)

    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "A3-v2#3025",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/A3-v2-3025/runtime_workspace"])
    expect(provisioner).not_to receive(:cleanup_task).with(
      hash_including(task_ref: "A3-v2#3026")
    )

    result = use_case.call

    expect(result.cleaned).to contain_exactly(
      an_object_having_attributes(
        task_ref: "A3-v2#3025",
        status: :done,
        cleaned_paths: ["/tmp/workspaces/A3-v2-3025/runtime_workspace"]
      )
    )
    expect(result.statuses).to eq([:done])
    expect(result.scopes).to eq(%i[ticket_workspace runtime_workspace])
    expect(result.dry_run).to be(false)
  end

  it "cleans terminal child workspaces when a parent is cleaned" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#201",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :done,
      child_refs: ["Sample#202", "Sample#203"]
    )
    done_child = A3::Domain::Task.new(
      ref: "Sample#202",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      parent_ref: parent_task.ref
    )
    active_child = A3::Domain::Task.new(
      ref: "Sample#203",
      kind: :child,
      edit_scope: [:repo_beta],
      status: :done,
      current_run_ref: "run-active",
      parent_ref: parent_task.ref
    )
    task_repository.save(parent_task)
    task_repository.save(done_child)
    task_repository.save(active_child)

    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Sample#201",
      workspace_ref: "Sample#201-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Sample-201-parent/runtime_workspace"])
    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Sample#202",
      parent_ref: "Sample#201",
      parent_workspace_ref: "Sample#201-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Sample-201-parent/children/Sample-202/ticket_workspace"])
    expect(provisioner).not_to receive(:cleanup_task).with(hash_including(task_ref: "Sample#203"))

    result = use_case.call

    expect(result.cleaned.map(&:task_ref)).to contain_exactly("Sample#201", "Sample#202")
  end

  it "does not clean stale child_refs that no longer point back to the parent" do
    stale_parent = A3::Domain::Task.new(
      ref: "Sample#205",
      kind: :parent,
      edit_scope: [:repo_alpha],
      status: :done,
      child_refs: ["Sample#204"]
    )
    reparented_child = A3::Domain::Task.new(
      ref: "Sample#204",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      parent_ref: "Sample#999"
    )
    task_repository.save(stale_parent)
    task_repository.save(reparented_child)

    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Sample#205",
      workspace_ref: "Sample#205-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return([])
    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Sample#204",
      parent_ref: "Sample#999",
      parent_workspace_ref: "Sample#999-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Sample-999-parent/children/Sample-204/ticket_workspace"])
    expect(provisioner).not_to receive(:cleanup_task).with(hash_including(task_ref: "Sample#204", parent_ref: "Sample#205"))

    result = use_case.call

    expect(result.cleaned.map(&:task_ref)).to contain_exactly("Sample#204")
  end

  it "supports dry-run cleanup for blocked quarantines" do
    blocked_task = A3::Domain::Task.new(
      ref: "A3-v2#3026",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :blocked
    )
    task_repository.save(blocked_task)

    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "A3-v2#3026",
      scopes: [:quarantine],
      dry_run: true
    ).and_return(["/tmp/quarantine/A3-v2-3026"])

    result = use_case.call(statuses: [:blocked], scopes: [:quarantine], dry_run: true)

    expect(result.cleaned).to contain_exactly(
      an_object_having_attributes(
        task_ref: "A3-v2#3026",
        status: :blocked,
        cleaned_paths: ["/tmp/quarantine/A3-v2-3026"]
      )
    )
    expect(result.dry_run).to be(true)
  end

  it "does not clean blocked task workspaces even when blocked status is explicitly requested" do
    blocked_task = A3::Domain::Task.new(
      ref: "A3-v2#3026",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :blocked
    )
    task_repository.save(blocked_task)

    expect(provisioner).not_to receive(:cleanup_task)

    result = use_case.call(statuses: [:blocked], scopes: %i[ticket_workspace runtime_workspace])

    expect(result.cleaned).to eq([])
    expect(result.statuses).to eq([:blocked])
    expect(result.scopes).to eq(%i[ticket_workspace runtime_workspace])
  end
end
