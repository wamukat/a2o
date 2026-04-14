# frozen_string_literal: true

RSpec.describe A3::Domain::PhaseSourcePolicy do
  subject(:policy) { described_class.new }

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

  it "builds implementation source descriptors from the work branch" do
    descriptor = policy.source_descriptor_for(task: child_task, phase: :implementation)

    expect(descriptor).to eq(
      A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/A3-v2-3030",
        task_ref: child_task.ref
      )
    )
  end

  it "builds parent review descriptors from the integration branch" do
    descriptor = policy.source_descriptor_for(task: parent_task, phase: :review)

    expect(descriptor).to eq(
      A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: parent_task.ref
      )
    )
  end

  it "builds parent verification and merge descriptors from the integration branch" do
    verification_descriptor = policy.source_descriptor_for(task: parent_task, phase: :verification)
    merge_descriptor = policy.source_descriptor_for(task: parent_task, phase: :merge)

    expect(verification_descriptor).to eq(
      A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: parent_task.ref
      )
    )
    expect(merge_descriptor).to eq(
      A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: parent_task.ref
      )
    )
  end


  it "adds a runtime namespace to generated branch refs when configured" do
    namespaced = described_class.new(branch_namespace: "runtime/a3-user-runtime-check")

    implementation_descriptor = namespaced.source_descriptor_for(task: child_task, phase: :implementation)
    parent_descriptor = namespaced.source_descriptor_for(task: parent_task, phase: :verification)

    expect(implementation_descriptor.ref).to eq("refs/heads/a3/runtime/a3-user-runtime-check/work/A3-v2-3030")
    expect(parent_descriptor.ref).to eq("refs/heads/a3/runtime/a3-user-runtime-check/parent/A3-v2-3022")
  end

  it "builds canonical review targets from the source ref" do
    review_target = policy.review_target_for(
      task: child_task,
      phase: :review,
      source_ref: "refs/heads/a3/work/A3-v2-3030"
    )

    expect(review_target).to eq(
      A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a3/work/A3-v2-3030",
        head_commit: "refs/heads/a3/work/A3-v2-3030",
        task_ref: child_task.ref,
        phase_ref: :review
      )
    )
  end
end
