# frozen_string_literal: true

RSpec.describe A3::Application::PlanNextDecompositionTask do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:sync_external_tasks) { instance_double(A3::Application::SyncExternalTasks, call: nil) }

  subject(:use_case) { described_class.new(task_repository: task_repository, sync_external_tasks: sync_external_tasks) }

  it "selects a trigger-investigate task for the decomposition domain" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5200",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 2
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5201",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :todo,
        labels: ["trigger:auto-implement"],
        priority: 5
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#5200")
    expect(result.active_task).to be_nil
    expect(result.candidates.map(&:ref)).to eq(["A3-v2#5200"])
    expect(sync_external_tasks).to have_received(:call)
  end

  it "keeps one active decomposition pipeline per project" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5200",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :in_progress,
        labels: ["trigger:investigate"],
        priority: 1
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5201",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 5
      )
    )

    result = use_case.call

    expect(result.task).to be_nil
    expect(result.active_task.ref).to eq("A3-v2#5200")
    expect(result.candidates.map(&:ref)).to eq(%w[A3-v2#5200 A3-v2#5201])
  end

  it "orders decomposition candidates with the scheduler selection policy" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5200",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 2
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5199",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 2
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#5199")
  end

  it "skips already-decomposed source tickets even if trigger remains" do
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5200",
        kind: :single,
        edit_scope: [:repo_alpha],
        status: :todo,
        labels: ["trigger:investigate", "a2o:decomposed"],
        priority: 5
      )
    )
    task_repository.save(
      A3::Domain::Task.new(
        ref: "A3-v2#5201",
        kind: :single,
        edit_scope: [:repo_beta],
        status: :todo,
        labels: ["trigger:investigate"],
        priority: 1
      )
    )

    result = use_case.call

    expect(result.task&.ref).to eq("A3-v2#5201")
    expect(result.candidates.map(&:ref)).to eq(["A3-v2#5201"])
  end
end
