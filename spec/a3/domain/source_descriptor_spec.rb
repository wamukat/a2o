# frozen_string_literal: true

RSpec.describe A3::Domain::SourceDescriptor do
  let(:child_task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3030",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      parent_ref: "A3-v2#3022"
    )
  end

  let(:parent_task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta]
    )
  end

  it "serializes and restores the persisted contract" do
    descriptor = described_class.new(
      workspace_kind: :runtime_workspace,
      source_type: :integration_record,
      ref: "refs/heads/a2o/work/3026",
      task_ref: "A3-v2#3026"
    )

    expect(descriptor.persisted_form).to eq(
      "workspace_kind" => "runtime_workspace",
      "source_type" => "integration_record",
      "ref" => "refs/heads/a2o/work/3026",
      "task_ref" => "A3-v2#3026"
    )
    expect(described_class.from_persisted_form(descriptor.persisted_form)).to eq(descriptor)
  end

  it "builds implementation descriptors through a semantic constructor" do
    descriptor = described_class.implementation(
      task_ref: child_task.ref,
      ref: "refs/heads/a2o/work/3030"
    )

    expect(descriptor.workspace_kind).to eq(:ticket_workspace)
    expect(descriptor.source_type).to eq(:branch_head)
    expect(descriptor.implementation?).to be(true)
    expect(descriptor.runtime?).to be(false)
  end

  it "builds runtime descriptors through a semantic constructor" do
    descriptor = described_class.runtime(
      task_ref: parent_task.ref,
      ref: "refs/heads/a2o/parent/3022",
      source_type: :integration_record
    )

    expect(descriptor.workspace_kind).to eq(:runtime_workspace)
    expect(descriptor.source_type).to eq(:integration_record)
    expect(descriptor.runtime?).to be(true)
    expect(descriptor.implementation?).to be(false)
  end

  it "builds phase-aligned descriptors from a task and phase" do
    implementation_descriptor = described_class.for_phase(
      task: child_task,
      phase: :implementation,
      ref: "refs/heads/a2o/work/3030"
    )
    review_descriptor = described_class.for_phase(
      task: parent_task,
      phase: :review,
      ref: "refs/heads/a2o/parent/3022"
    )

    expect(implementation_descriptor).to eq(
      described_class.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3030",
        task_ref: child_task.ref
      )
    )
    expect(review_descriptor).to eq(
      described_class.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/3022",
        task_ref: parent_task.ref
      )
    )
  end

  it "rejects unsupported source types" do
    expect do
      described_class.new(
        workspace_kind: :runtime_workspace,
        source_type: :legacy_snapshot,
        ref: "refs/heads/a2o/work/3026",
        task_ref: "A3-v2#3026"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported source_type/)
  end

  it "rejects unsupported workspace kinds" do
    expect do
      described_class.new(
        workspace_kind: :support_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3026",
        task_ref: "A3-v2#3026"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported workspace_kind/)
  end

  it "rejects unsupported phase values in the semantic constructor" do
    expect do
      described_class.for_phase(
        task: child_task,
        phase: :planning,
        ref: "refs/heads/a2o/work/3030"
      )
    end.to raise_error(A3::Domain::InvalidPhaseError, /unsupported phase/)
  end
end
