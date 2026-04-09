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
