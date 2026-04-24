# frozen_string_literal: true

require "json"
require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::WorkerProtocol do
  let(:tmpdir) { Dir.mktmpdir("a3-worker-protocol") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(tmpdir).join("workspace"),
      source_descriptor: source_descriptor,
      slot_paths: {
        repo_beta: Pathname(tmpdir).join("workspace", "repo-beta")
      }
    )
  end
  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3028",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta]
    )
  end
  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
  end
  let(:task_packet) do
    A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: 3028,
      kind: task.kind,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      parent_ref: task.parent_ref,
      child_refs: task.child_refs,
      title: "Review worker protocol",
      description: "Review agent materialized worker protocol.",
      status: "In progress",
      labels: []
    )
  end
  let(:phase_runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :ui_app,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
  end

  before do
    FileUtils.mkdir_p(workspace.root_path)
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "exposes the same request payload that write_request persists" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    protocol.write_request(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    request_path = workspace.root_path.join(".a2o", "worker-request.json")
    persisted = JSON.parse(request_path.read)
    expect(persisted).to eq(request_form)
    expect(request_path.read).to include("\n  \"task_ref\":")
    expect(request_form).to include(
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "review",
      "skill" => "task review"
    )
  end

  it "marks command request intent when used by project verification commands" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: nil,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet,
      command_intent: :verification
    )

    expect(request_form).to include(
      "command_intent" => "verification",
      "slot_paths" => {
        "repo_beta" => workspace.slot_paths.fetch(:repo_beta).to_s
      },
      "phase_runtime" => hash_including(
        "task_kind" => "child",
        "repo_scope" => "ui_app"
      )
    )
  end

  it "normalizes project repo labels in review_disposition repo_scope" do
    result = described_class.new(
      repo_scope_aliases: { "repo:both" => "both" },
      review_disposition_repo_scopes: %w[repo_alpha repo_beta both]
    ).build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo:both",
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("review_disposition").fetch("repo_scope")).to eq("both")
  end

  it "does not hardcode project repo labels when normalizing review_disposition repo_scope" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo:both",
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include("review_disposition.repo_scope must be one of repo_beta")
  end

  it "requires review_disposition for implementation success" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["marker.txt"] }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: false)
    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "review_disposition must be present for implementation success"
    )
  end

  it "accepts and normalizes structured skill feedback without changing successful worker flow" do
    result = described_class.new(
      repo_scope_aliases: { "repo:both" => "both" },
      review_disposition_repo_scopes: %w[repo_alpha repo_beta both]
    ).build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo_beta",
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        },
        "skill_feedback" => {
          "schema" => "a2o-skill-feedback/v1",
          "category" => "missing_context",
          "summary" => "Add fixture update guidance before verification.",
          "repo_scope" => "repo:both",
          "skill_path" => "skills/implementation/base.md",
          "proposal" => {
            "target" => "project_skill",
            "suggested_patch" => "Check fixture update command before running verification."
          },
          "confidence" => "medium"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: true)
    expect(result.skill_feedback.first).to include(
      "category" => "missing_context",
      "repo_scope" => "both",
      "summary" => "Add fixture update guidance before verification."
    )
  end

  it "rejects malformed skill feedback when present" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "worker failed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "failing_command" => "review_worker",
        "observed_state" => "invalid feedback",
        "skill_feedback" => {
          "category" => "missing_context",
          "proposal" => {}
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false)
    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "skill_feedback[0].summary must be a string",
      "skill_feedback[0].proposal.target must be a string"
    )
  end

  def implementation_run
    A3::Domain::Run.new(
      ref: "run-implementation-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha, :repo_beta],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "head-1"
      )
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task.ref, ref: "abc123")
  end
end
