# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::AgentJobRequest do
  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.runtime_detached_commit(
      task_ref: "Portal#42",
      ref: "abc123"
    )
  end

  it "serializes the job contract without shell-specific command strings" do
    request = described_class.new(
      job_id: "job-portal-42-verification",
      task_ref: "Portal#42",
      phase: :verification,
      runtime_profile: "portal-dev-env",
      source_descriptor: source_descriptor,
      working_dir: "/workspace/member-portal-starters",
      command: "task",
      args: ["ops:flow:standard"],
      env: { A3_ROOT_DIR: "/workspace" },
      timeout_seconds: 1800,
      artifact_rules: [
        {
          role: "junit",
          glob: "target/surefire-reports/*.xml",
          retention_class: "evidence"
        }
      ]
    )

    expect(request.request_form).to eq(
      "job_id" => "job-portal-42-verification",
      "task_ref" => "Portal#42",
      "phase" => "verification",
      "runtime_profile" => "portal-dev-env",
      "source_descriptor" => source_descriptor.persisted_form,
      "working_dir" => "/workspace/member-portal-starters",
      "command" => "task",
      "args" => ["ops:flow:standard"],
      "env" => { "A3_ROOT_DIR" => "/workspace" },
      "timeout_seconds" => 1800,
      "artifact_rules" => [
        {
          "role" => "junit",
          "glob" => "target/surefire-reports/*.xml",
          "retention_class" => "evidence"
        }
      ]
    )
  end

  it "round-trips from the request form" do
    request = described_class.new(
      job_id: "job-portal-42-implementation",
      task_ref: "Portal#42",
      phase: "implementation",
      runtime_profile: "host-local",
      source_descriptor: A3::Domain::SourceDescriptor.implementation(task_ref: "Portal#42", ref: "feature/a3"),
      working_dir: ".",
      command: "ruby",
      args: ["scripts/a3/worker.rb"],
      env: {},
      timeout_seconds: 600,
      artifact_rules: []
    )

    expect(described_class.from_request_form(request.request_form)).to eq(request)
  end

  it "fails closed on unsupported phases and non-positive timeouts" do
    expect do
      described_class.new(
        job_id: "job-1",
        task_ref: "Portal#42",
        phase: :deploy,
        runtime_profile: "host-local",
        source_descriptor: source_descriptor,
        working_dir: ".",
        command: "task",
        args: [],
        env: {},
        timeout_seconds: 60,
        artifact_rules: []
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent job phase/)

    expect do
      described_class.new(
        job_id: "job-1",
        task_ref: "Portal#42",
        phase: :verification,
        runtime_profile: "host-local",
        source_descriptor: source_descriptor,
        working_dir: ".",
        command: "task",
        args: [],
        env: {},
        timeout_seconds: 0,
        artifact_rules: []
      )
    end.to raise_error(A3::Domain::ConfigurationError, /timeout_seconds/)
  end
end
