# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::AgentJobResult do
  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.runtime_detached_commit(
      task_ref: "Portal#42",
      ref: "abc123"
    )
  end

  let(:workspace_descriptor) do
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "portal-dev-env",
      workspace_id: "workspace-portal-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {
        repo_alpha: {
          "runtime_path" => "/workspace/member-portal-starters",
          "head_ref" => "abc123",
          "dirty" => false
        }
      }
    )
  end

  it "serializes upload-backed logs and artifacts" do
    log_upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-log-1",
      role: "combined-log",
      digest: "sha256:abc",
      byte_size: 128,
      retention_class: :diagnostic,
      media_type: "text/plain"
    )
    junit_upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "art-junit-1",
      role: "junit",
      digest: "sha256:def",
      byte_size: 256,
      retention_class: :evidence,
      media_type: "application/xml"
    )

    result = described_class.new(
      job_id: "job-portal-42-verification",
      status: :failed,
      exit_code: 1,
      started_at: "2026-04-11T08:00:00+09:00",
      finished_at: "2026-04-11T08:01:00+09:00",
      summary: "task ops:flow:standard failed",
      log_uploads: [log_upload],
      artifact_uploads: [junit_upload],
      workspace_descriptor: workspace_descriptor,
      heartbeat: "2026-04-11T08:00:30+09:00"
    )

    expect(result.result_form).to include(
      "job_id" => "job-portal-42-verification",
      "status" => "failed",
      "exit_code" => 1,
      "summary" => "task ops:flow:standard failed"
    )
    expect(result.result_form.fetch("log_uploads")).to eq([log_upload.persisted_form])
    expect(result.result_form.fetch("artifact_uploads")).to eq([junit_upload.persisted_form])
    expect(result.result_form.fetch("workspace_descriptor")).to eq(workspace_descriptor.persisted_form)
  end

  it "round-trips from the result form" do
    result = described_class.new(
      job_id: "job-portal-42-verification",
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
          "retention_class" => "diagnostic"
        }
      ],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      worker_protocol_result: {
        status: "succeeded",
        task_ref: "Portal#42"
      },
      heartbeat: nil
    )

    expect(described_class.from_result_form(result.result_form)).to eq(result)
    expect(result.result_form.fetch("worker_protocol_result")).to eq(
      "status" => "succeeded",
      "task_ref" => "Portal#42"
    )
  end

  it "rejects local path-only log and artifact result fields" do
    result_form = {
      "job_id" => "job-portal-42-verification",
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
        "retention_class" => "diagnostic",
        "path" => "/tmp/combined.log"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /not local paths/)
  end

  it "validates workspace descriptor kind against the source descriptor" do
    expect do
      A3::Domain::AgentWorkspaceDescriptor.new(
        workspace_kind: :ticket_workspace,
        runtime_profile: "portal-dev-env",
        workspace_id: "workspace-portal-42",
        source_descriptor: source_descriptor,
        slot_descriptors: {}
      )
    end.to raise_error(A3::Domain::ConfigurationError, /workspace kind/)
  end
end
