# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::AgentJobResult do
  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.runtime_detached_commit(
      task_ref: "Sample#42",
      ref: "abc123"
    )
  end

  def workspace_descriptor(project_key: nil)
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      project_key: project_key,
      runtime_profile: "host-local-agent",
      workspace_id: "workspace-sample-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {
        repo_alpha: {
          "runtime_path" => "/workspace/sample-catalog-service",
          "head_ref" => "abc123",
          "dirty" => false
        }
      }
    )
  end

  it "serializes upload-backed logs and artifacts" do
    log_upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-log-1",
      project_key: "a2o",
      role: "combined-log",
      digest: "sha256:abc",
      byte_size: 128,
      retention_class: :analysis,
      media_type: "text/plain"
    )
    junit_upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-junit-1",
      project_key: "a2o",
      role: "junit",
      digest: "sha256:def",
      byte_size: 256,
      retention_class: :evidence,
      media_type: "application/xml"
    )

    result = described_class.new(
      job_id: "job-sample-42-verification",
      project_key: "a2o",
      status: :failed,
      exit_code: 1,
      started_at: "2026-04-11T08:00:00+09:00",
      finished_at: "2026-04-11T08:01:00+09:00",
      summary: "task ops:flow:standard failed",
      log_uploads: [log_upload],
      artifact_uploads: [junit_upload],
      workspace_descriptor: workspace_descriptor(project_key: "a2o"),
      heartbeat: "2026-04-11T08:00:30+09:00"
    )

    expect(result.result_form).to include(
      "job_id" => "job-sample-42-verification",
      "project_key" => "a2o",
      "status" => "failed",
      "exit_code" => 1,
      "summary" => "task ops:flow:standard failed"
    )
    expect(result.result_form.fetch("log_uploads")).to eq([log_upload.persisted_form])
    expect(result.result_form.fetch("artifact_uploads")).to eq([junit_upload.persisted_form])
    expect(result.result_form.fetch("workspace_descriptor")).to eq(workspace_descriptor(project_key: "a2o").persisted_form)
  end

  it "rejects project identity mismatches inside job results" do
    log_upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-log-1",
      project_key: "other",
      role: "combined-log",
      digest: "sha256:abc",
      byte_size: 128,
      retention_class: :analysis
    )

    expect do
      described_class.new(
        job_id: "job-a2o-312",
        project_key: "a2o",
        status: :succeeded,
        exit_code: 0,
        started_at: "2026-04-11T08:00:00Z",
        finished_at: "2026-04-11T08:01:00Z",
        summary: "ok",
        log_uploads: [log_upload],
        artifact_uploads: [],
        workspace_descriptor: workspace_descriptor(project_key: "a2o"),
        heartbeat: nil
      )
    end.to raise_error(A3::Domain::ConfigurationError, /project_key mismatch/)
  end

  it "round-trips from the result form" do
    result = described_class.new(
      job_id: "job-sample-42-verification",
      status: "succeeded",
      exit_code: 0,
      started_at: "2026-04-11T08:00:00+09:00",
      finished_at: "2026-04-11T08:01:00+09:00",
      summary: "all checks passed",
      log_uploads: [
        {
          "artifact_id" => "art-log-1",
          "role" => "combined-log",
          "digest" => "sha256:abc",
          "byte_size" => 128,
          "retention_class" => "analysis"
        }
      ],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      worker_protocol_result: {
        status: "succeeded",
        task_ref: "Sample#42"
      },
      heartbeat: nil
    )

    expect(described_class.from_result_form(result.result_form)).to eq(result)
    expect(result.result_form.fetch("worker_protocol_result")).to eq(
      "status" => "succeeded",
      "task_ref" => "Sample#42"
    )
  end

  it "round-trips workspace descriptor topology" do
    descriptor = A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local-agent",
      workspace_id: "Sample-134-children-Sample-135-implementation-run-implementation",
      source_descriptor: source_descriptor,
      topology: {
        kind: "parent_child",
        parent_ref: "Sample#134",
        child_ref: "Sample#135",
        parent_workspace_id: "Sample-134-parent",
        relative_path: "children/Sample-135/ticket_workspace"
      },
      slot_descriptors: {
        repo_alpha: {
          "runtime_path" => "/workspace/Sample-134-parent/children/Sample-135/ticket_workspace/repo-alpha"
        }
      }
    )

    expect(A3::Domain::AgentWorkspaceDescriptor.from_persisted_form(descriptor.persisted_form)).to eq(descriptor)
    expect(descriptor.persisted_form.fetch("topology")).to eq(
      "kind" => "parent_child",
      "parent_ref" => "Sample#134",
      "child_ref" => "Sample#135",
      "parent_workspace_id" => "Sample-134-parent",
      "relative_path" => "children/Sample-135/ticket_workspace"
    )
  end

  it "serializes project identity in job results, workspace descriptors, and artifact uploads" do
    descriptor = A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      project_key: "a2o",
      runtime_profile: "host-local-agent",
      workspace_id: "workspace-a2o-312",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
    upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-log-1",
      project_key: "a2o",
      role: "combined-log",
      digest: "sha256:abc",
      byte_size: 128,
      retention_class: :analysis
    )
    result = described_class.new(
      job_id: "job-a2o-312",
      project_key: "a2o",
      status: :succeeded,
      exit_code: 0,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:01:00Z",
      summary: "ok",
      log_uploads: [upload],
      artifact_uploads: [],
      workspace_descriptor: descriptor,
      heartbeat: nil
    )

    expect(result.result_form.fetch("project_key")).to eq("a2o")
    expect(described_class.from_result_form(result.result_form)).to eq(result)
    expect(descriptor.persisted_form.fetch("project_key")).to eq("a2o")
    expect(A3::Domain::AgentWorkspaceDescriptor.from_persisted_form(descriptor.persisted_form)).to eq(descriptor)
    expect(upload.persisted_form.fetch("project_key")).to eq("a2o")
    expect(A3::Domain::AgentArtifactUpload.from_persisted_form(upload.persisted_form)).to eq(upload)
  end

  it "rejects local path-only log and artifact result fields" do
    result_form = {
      "job_id" => "job-sample-42-verification",
      "status" => "failed",
      "exit_code" => 1,
      "started_at" => "2026-04-11T08:00:00+09:00",
      "finished_at" => "2026-04-11T08:01:00+09:00",
      "summary" => "failed",
      "stdout_log" => "/tmp/stdout.log",
      "stderr_log" => "/tmp/stderr.log",
      "combined_log" => "/tmp/combined.log",
      "artifacts" => ["/tmp/report.xml"],
      "log_uploads" => [],
      "artifact_uploads" => [],
      "workspace_descriptor" => workspace_descriptor.persisted_form
    }

    expect do
      described_class.from_result_form(result_form)
    end.to raise_error(A3::Domain::ConfigurationError, /upload references/)
  end

  it "rejects artifact uploads that contain local paths" do
    expect do
      A3::Domain::AgentArtifactUpload.from_persisted_form(
        "artifact_id" => "art-log-1",
        "role" => "combined-log",
        "digest" => "sha256:abc",
        "byte_size" => 128,
        "retention_class" => "analysis",
        "path" => "/tmp/combined.log"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /not local paths/)
  end

  it "validates workspace descriptor kind against the source descriptor" do
    expect do
      A3::Domain::AgentWorkspaceDescriptor.new(
        workspace_kind: :ticket_workspace,
        runtime_profile: "host-local-agent",
        workspace_id: "workspace-sample-42",
        source_descriptor: source_descriptor,
        slot_descriptors: {}
      )
    end.to raise_error(A3::Domain::ConfigurationError, /workspace kind/)
  end
end
