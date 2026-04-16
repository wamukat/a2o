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
      ref: "Portal#201",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      status: :done,
      child_refs: ["Portal#202", "Portal#203"]
    )
    done_child = A3::Domain::Task.new(
      ref: "Portal#202",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      parent_ref: parent_task.ref
    )
    active_child = A3::Domain::Task.new(
      ref: "Portal#203",
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
      task_ref: "Portal#201",
      workspace_ref: "Portal#201-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Portal-201-parent/runtime_workspace"])
    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Portal#202",
      parent_ref: "Portal#201",
      parent_workspace_ref: "Portal#201-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Portal-201-parent/children/Portal-202/ticket_workspace"])
    expect(provisioner).not_to receive(:cleanup_task).with(hash_including(task_ref: "Portal#203"))

    result = use_case.call

    expect(result.cleaned.map(&:task_ref)).to contain_exactly("Portal#201", "Portal#202")
  end

  it "does not clean stale child_refs that no longer point back to the parent" do
    stale_parent = A3::Domain::Task.new(
      ref: "Portal#205",
      kind: :parent,
      edit_scope: [:repo_alpha],
      status: :done,
      child_refs: ["Portal#204"]
    )
    reparented_child = A3::Domain::Task.new(
      ref: "Portal#204",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      parent_ref: "Portal#999"
    )
    task_repository.save(stale_parent)
    task_repository.save(reparented_child)

    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Portal#205",
      workspace_ref: "Portal#205-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return([])
    expect(provisioner).to receive(:cleanup_task).with(
      task_ref: "Portal#204",
      parent_ref: "Portal#999",
      parent_workspace_ref: "Portal#999-parent",
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    ).and_return(["/tmp/workspaces/Portal-999-parent/children/Portal-204/ticket_workspace"])
    expect(provisioner).not_to receive(:cleanup_task).with(hash_including(task_ref: "Portal#204", parent_ref: "Portal#205"))

    result = use_case.call

    expect(result.cleaned.map(&:task_ref)).to contain_exactly("Portal#204")
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
end
