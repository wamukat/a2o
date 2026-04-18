# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentWorkspaceRequestBuilder do
  let(:source_descriptor) { A3::Domain::SourceDescriptor.implementation(task_ref: "Sample#42", ref: "refs/heads/a2o/work/Sample-42") }
  let(:task) do
    A3::Domain::Task.new(
      ref: "Sample#42",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_beta]
    )
  end
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-local-workspace",
      source_descriptor: source_descriptor,
      slot_paths: {}
    )
  end

  it "builds all configured slots and marks edit scope with read-write access" do
    request = support_ref_builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.workspace_kind).to eq(:ticket_workspace)
    expect(request.workspace_id).to eq("Sample-42-implementation-run-implementation")
    expect(request.publish_policy).to eq(
      "mode" => "commit_all_edit_target_changes_on_worker_success",
      "commit_message" => "A2O implementation update for Sample#42"
    )
    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a2o/work/Sample-42",
      "checkout" => "worktree_branch",
      "access" => "read_write",
      "sync_class" => "eager",
      "ownership" => "edit_target",
      "required" => true
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "checkout" => "worktree_branch",
      "access" => "read_only",
      "sync_class" => "lazy_but_guaranteed",
      "ownership" => "support",
      "required" => true
    )
    expect(request.slots.fetch("repo_alpha").fetch("source")).to eq(
      "kind" => "local_git",
      "alias" => "sample-alpha"
    )
  end

  it "uses parent-owned workspace ids for child tasks with a parent ref" do
    parented_task = A3::Domain::Task.new(
      ref: "Sample#135",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      parent_ref: "Sample#134"
    )
    parented_run = A3::Domain::Run.new(
      ref: "run-implementation",
      task_ref: parented_task.ref,
      phase: :implementation,
      workspace_kind: workspace.workspace_kind,
      source_descriptor: A3::Domain::SourceDescriptor.implementation(
        task_ref: parented_task.ref,
        ref: "refs/heads/a2o/work/Sample-135"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: parented_task.edit_scope,
        verification_scope: parented_task.verification_scope,
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parented_task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/Sample-135"
      )
    )

    request = support_ref_builder.call(workspace: workspace, task: parented_task, run: parented_run)

    expect(request.workspace_id).to eq("Sample-134-children-Sample-135-implementation-run-implementation")
    expect(request.topology).to eq(
      "kind" => "parent_child",
      "parent_ref" => "Sample#134",
      "child_ref" => "Sample#135",
      "parent_workspace_id" => "Sample-134-parent",
      "relative_path" => "children/Sample-135/ticket_workspace"
    )
    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a2o/work/Sample-135",
      "bootstrap_ref" => "refs/heads/a2o/parent/Sample-134",
      "bootstrap_base_ref" => "refs/heads/feature/prototype",
      "ownership" => "edit_target"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/a2o/parent/Sample-134",
      "bootstrap_ref" => "refs/heads/feature/prototype",
      "ownership" => "support"
    )
  end

  it "uses the default support ref for standalone non-edit slots" do
    builder = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    )

    request = builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a2o/work/Sample-42",
      "ownership" => "edit_target"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/feature/prototype",
      "ownership" => "support",
      "access" => "read_only"
    )
  end

  it "uses the parent integration ref for parent support slots" do
    parent_task = A3::Domain::Task.new(
      ref: "Sample#173",
      kind: :parent,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-verification",
      task_ref: parent_task.ref,
      phase: :verification,
      workspace_kind: workspace.workspace_kind,
      source_descriptor: A3::Domain::SourceDescriptor.implementation(
        task_ref: parent_task.ref,
        ref: "refs/heads/a2o/parent/Sample-173"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: parent_task.edit_scope,
        verification_scope: parent_task.verification_scope,
        ownership_scope: :parent
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/parent/Sample-173"
      )
    )

    request = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: parent_task, run: parent_run)

    expect(request.workspace_id).to eq("Sample-173-parent")
    expect(request.slots.fetch("repo_alpha")).to include(
      "ref" => "refs/heads/a2o/parent/Sample-173",
      "bootstrap_ref" => "refs/heads/feature/prototype",
      "ownership" => "edit_target"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/a2o/parent/Sample-173",
      "bootstrap_ref" => "refs/heads/feature/prototype",
      "ownership" => "support"
    )
  end


  it "uses the runtime branch namespace for generated parent support refs" do
    parent_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-parent-runtime-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(
        task_ref: "Sample#173",
        ref: "refs/heads/a2o/runtime/a3-user-runtime-check/parent/Sample-173"
      ),
      slot_paths: {}
    )
    parent_task = A3::Domain::Task.new(
      ref: "Sample#173",
      kind: :parent,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-verification",
      task_ref: parent_task.ref,
      phase: :verification,
      workspace_kind: parent_workspace.workspace_kind,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(
        task_ref: parent_task.ref,
        ref: "refs/heads/a2o/runtime/a3-user-runtime-check/parent/Sample-173"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: parent_task.edit_scope,
        verification_scope: parent_task.verification_scope,
        ownership_scope: :parent
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/runtime/a3-user-runtime-check/parent/Sample-173"
      )
    )

    request = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype",
      branch_namespace: "runtime/a3-user-runtime-check"
    ).call(workspace: parent_workspace, task: parent_task, run: parent_run)

    expect(request.slots.fetch("repo_alpha")).to include("ref" => "refs/heads/a2o/runtime/a3-user-runtime-check/parent/Sample-173")
    expect(request.slots.fetch("repo_beta")).to include("ref" => "refs/heads/a2o/runtime/a3-user-runtime-check/parent/Sample-173")
  end

  it "uses slot-specific support refs when multiple support repositories are configured" do
    multi_support_builder = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta",
        repo_gamma: "sample-gamma"
      },
      support_refs: {
        "repo_beta" => "refs/heads/support/beta",
        "repo_gamma" => "refs/heads/support/gamma"
      }
    )

    request = multi_support_builder.call(workspace: workspace, task: task, run: run(:implementation))

    expect(request.slots.fetch("repo_alpha")).to include("ref" => "refs/heads/a2o/work/Sample-42")
    expect(request.slots.fetch("repo_beta")).to include("ref" => "refs/heads/support/beta")
    expect(request.slots.fetch("repo_gamma")).to include("ref" => "refs/heads/support/gamma")
  end

  it "makes only edit target slots writable and publishable for remediation commands" do
    request = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: task, run: run(:verification), command_intent: :remediation)

    expect(request.publish_policy).to eq(
      "mode" => "commit_all_edit_target_changes_on_success",
      "commit_message" => "A2O remediation update for Sample#42"
    )
    expect(request.slots.fetch("repo_alpha")).to include("access" => "read_write", "ownership" => "edit_target")
    expect(request.slots.fetch("repo_beta")).to include("access" => "read_only", "ownership" => "support")
  end

  it "keeps support slots present for verification even when the scope is narrow" do
    request = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: task, run: run(:verification))

    expect(request.publish_policy).to be_nil
    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.fetch("repo_alpha")).to include(
      "access" => "read_only",
      "sync_class" => "eager"
    )
    expect(request.slots.fetch("repo_beta")).to include(
      "ref" => "refs/heads/feature/prototype",
      "access" => "read_only",
      "sync_class" => "lazy_but_guaranteed"
    )
  end

  it "fails closed when support slots are requested without a support ref" do
    expect do
      builder.call(workspace: workspace, task: task, run: run(:implementation))
    end.to raise_error(A3::Domain::ConfigurationError, /support slot repo_beta requires --agent-support-ref/)
  end

  it "builds review slots from edit and verification scopes with edit slots writable" do
    request = described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    ).call(workspace: workspace, task: task, run: run(:review))

    expect(request.slots.keys).to eq(%w[repo_alpha repo_beta])
    expect(request.slots.transform_values { |slot| slot.fetch("access") }).to eq(
      "repo_alpha" => "read_write",
      "repo_beta" => "read_only"
    )
  end

  it "uses the configured source alias keys as the required slot universe" do
    builder = described_class.new(source_aliases: { repo_alpha: "sample-alpha" })

    request = builder.call(workspace: workspace, task: task, run: run(:verification))

    expect(request.slots.keys).to eq(["repo_alpha"])
  end

  it "fails for unsupported merge phase" do
    expect do
      builder.call(workspace: workspace, task: task, run: run(:merge))
    end.to raise_error(A3::Domain::ConfigurationError, /not supported for phase merge/)
  end

  it "fails fast for unsupported workspace policies" do
    expect do
      described_class.new(source_aliases: { repo_alpha: "sample-alpha" }, cleanup_policy: :delete_everything)
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent workspace cleanup_policy/)
  end

  def builder
    described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      }
    )
  end

  def support_ref_builder
    described_class.new(
      source_aliases: {
        repo_alpha: "sample-alpha",
        repo_beta: "sample-beta"
      },
      support_ref: "refs/heads/feature/prototype"
    )
  end

  def run(phase)
    A3::Domain::Run.new(
      ref: "run-#{phase}",
      task_ref: task.ref,
      phase: phase,
      workspace_kind: workspace.workspace_kind,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: task.edit_scope,
        verification_scope: task.verification_scope,
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
  end
end
