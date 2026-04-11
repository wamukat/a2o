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

  it "builds an agent materialized HTTP worker gateway with explicit source aliases" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: {
        worker_gateway: "agent-http",
        worker_command: "sh",
        worker_command_args: ["-lc", "worker"],
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "agent-materialized",
        agent_source_aliases: {
          "repo_alpha" => "portal-alpha",
          "repo_beta" => "portal-beta"
        },
        agent_workspace_cleanup_policy: :cleanup_after_job
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

  it "requires explicit supported workspace mode for the agent HTTP worker gateway" do
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
    end.to raise_error(ArgumentError, /agent-shared-workspace-mode same-path or agent-materialized/)
  end

  it "requires explicit source aliases for agent materialized mode" do
    expect do
      A3::CLI.send(
        :build_worker_gateway,
        options: {
          worker_gateway: "agent-http",
          worker_command: "sh",
          worker_command_args: [],
          agent_control_plane_url: "http://127.0.0.1:4567",
          agent_shared_workspace_mode: "agent-materialized"
        },
        command_runner: instance_double(A3::Infra::LocalCommandRunner)
      )
    end.to raise_error(ArgumentError, /agent-source-alias/)
  end

  it "builds an agent HTTP verification command runner when required options are provided" do
    runner = A3::CLI.send(
      :build_command_runner,
      options: {
        verification_command_runner: "agent-http",
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "agent-materialized",
        agent_source_aliases: {
          "repo_alpha" => "portal-alpha"
        }
      },
      fallback: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(runner).to be_a(A3::Infra::AgentCommandRunner)
  end

  it "resolves the agent auth token from a token file when no direct token is configured" do
    Dir.mktmpdir do |dir|
      token_path = File.join(dir, "agent-token")
      File.write(token_path, "file-token\n")

      token = A3::CLI.send(
        :agent_auth_token,
        agent_token: "",
        agent_token_file: token_path
      )

      expect(token).to eq("file-token")
    end
  end

  it "prefers a direct agent auth token over a token file" do
    Dir.mktmpdir do |dir|
      token_path = File.join(dir, "agent-token")
      File.write(token_path, "file-token\n")

      token = A3::CLI.send(
        :agent_auth_token,
        agent_token: "direct-token",
        agent_token_file: token_path
      )

      expect(token).to eq("direct-token")
    end
  end

  it "requires a control-plane URL for the agent HTTP verification command runner" do
    expect do
      A3::CLI.send(
        :build_command_runner,
        options: {
          verification_command_runner: "agent-http",
          agent_shared_workspace_mode: "same-path"
        },
        fallback: instance_double(A3::Infra::LocalCommandRunner)
      )
    end.to raise_error(ArgumentError, /agent-control-plane-url/)
  end
end
