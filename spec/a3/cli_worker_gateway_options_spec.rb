# frozen_string_literal: true

require "spec_helper"

RSpec.describe "A3 CLI worker gateway options" do
  it "defaults to the local worker gateway" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: { worker_command_args: [] },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::LocalWorkerGateway)
  end

  it "builds an agent HTTP worker gateway when required options are provided" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: {
        worker_gateway: "agent-http",
        worker_command: "ruby",
        worker_command_args: ["worker.rb"],
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "same-path"
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::AgentWorkerGateway)
  end

  it "requires a control-plane URL for the agent HTTP worker gateway" do
    expect do
      A3::CLI.send(
        :build_worker_gateway,
        options: {
          worker_gateway: "agent-http",
          worker_command: "ruby",
          worker_command_args: [],
          agent_shared_workspace_mode: "same-path"
        },
        command_runner: instance_double(A3::Infra::LocalCommandRunner)
      )
    end.to raise_error(ArgumentError, /agent-control-plane-url/)
  end

  it "requires explicit same-path workspace mode for the agent HTTP worker gateway" do
    expect do
      A3::CLI.send(
        :build_worker_gateway,
        options: {
          worker_gateway: "agent-http",
          worker_command: "ruby",
          worker_command_args: [],
          agent_control_plane_url: "http://127.0.0.1:4567"
        },
        command_runner: instance_double(A3::Infra::LocalCommandRunner)
      )
    end.to raise_error(ArgumentError, /agent-shared-workspace-mode same-path/)
  end
end
