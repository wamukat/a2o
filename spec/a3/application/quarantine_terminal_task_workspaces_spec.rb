# frozen_string_literal: true

RSpec.describe A3::Application::QuarantineTerminalTaskWorkspaces do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:provisioner) { instance_double(A3::Infra::LocalWorkspaceProvisioner) }

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      provisioner: provisioner
    )
  end

  it "quarantines done tasks that have no active run while preserving blocked workspaces" do
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
    running_task = A3::Domain::Task.new(
      ref: "A3-v2#3027",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :done,
      current_run_ref: "run-1"
    )
    task_repository.save(done_task)
    task_repository.save(blocked_task)
    task_repository.save(running_task)

    expect(provisioner).to receive(:quarantine_task).with(task_ref: "A3-v2#3025").and_return("/tmp/quarantine/A3-v2-3025")
    expect(provisioner).not_to receive(:quarantine_task).with(task_ref: "A3-v2#3026")
    expect(provisioner).not_to receive(:quarantine_task).with(task_ref: "A3-v2#3027")

    result = use_case.call

    expect(result.quarantined).to contain_exactly(
      an_object_having_attributes(task_ref: "A3-v2#3025", quarantine_path: "/tmp/quarantine/A3-v2-3025")
    )
  end
end
