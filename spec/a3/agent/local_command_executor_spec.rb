# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Agent::LocalCommandExecutor do
  let(:tmpdir) { Dir.mktmpdir }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "executes a command in the requested working directory" do
    request = agent_request(command: "ruby", args: ["-e", "puts Dir.pwd"], timeout_seconds: 10)

    result = described_class.new.call(request)

    expect(result.status).to eq(:succeeded)
    expect(result.exit_code).to eq(0)
    expect(result.combined_log).to include(tmpdir)
  end

  it "marks missing commands as failed" do
    request = agent_request(command: "missing-a3-command", args: [], timeout_seconds: 10)

    result = described_class.new.call(request)

    expect(result.status).to eq(:failed)
    expect(result.exit_code).to eq(127)
    expect(result.combined_log).to include("No such file")
  end

  it "marks commands that exceed the job timeout as timed out" do
    request = agent_request(command: "ruby", args: ["-e", "sleep 2"], timeout_seconds: 1)

    result = described_class.new.call(request)

    expect(result.status).to eq(:timed_out)
    expect(result.exit_code).to be_nil
    expect(result.combined_log).to include("timed out")
  end

  def agent_request(command:, args:, timeout_seconds:)
    A3::Domain::AgentJobRequest.new(
      job_id: "job-1",
      task_ref: "Portal#42",
      phase: :verification,
      runtime_profile: "host-local",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "abc123"),
      working_dir: tmpdir,
      command: command,
      args: args,
      env: {},
      timeout_seconds: timeout_seconds,
      artifact_rules: []
    )
  end
end
