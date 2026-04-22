# frozen_string_literal: true

require "spec_helper"

RSpec.describe "A3 CLI worker gateway options" do
  it "defaults to a disabled worker gateway" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: { worker_command_args: [] },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::DisabledWorkerGateway)
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

  it "passes explicit agent env options to an agent HTTP worker gateway" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: {
        worker_gateway: "agent-http",
        worker_command: "ruby",
        worker_command_args: ["worker.rb"],
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "same-path",
        agent_env: {
          "A3_ROOT_DIR" => "/host/a3"
        }
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway.instance_variable_get(:@env)).to eq("A3_ROOT_DIR" => "/host/a3")
  end

  it "passes engine-managed agent environment options to an agent HTTP worker gateway" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: {
        worker_gateway: "agent-http",
        worker_command: "ruby",
        worker_command_args: ["worker.rb"],
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "same-path",
        agent_workspace_root: "/agent/workspaces",
        agent_source_paths: {
          "sample-catalog-service" => "/agent/repos/starters"
        },
        agent_env: {
          "A3_ROOT_DIR" => "/agent/a3"
        },
        agent_required_bins: ["git", "task"]
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway.instance_variable_get(:@agent_environment)).to eq(
      "workspace_root" => "/agent/workspaces",
      "source_paths" => {
        "sample-catalog-service" => "/agent/repos/starters"
      },
      "env" => {
        "A3_ROOT_DIR" => "/agent/a3"
      },
      "required_bins" => ["git", "task"]
    )
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
        repo_sources: {
          repo_alpha: "/repos/repo_alpha",
          repo_beta: "/repos/repo_beta"
        },
        agent_source_aliases: {
          "repo_alpha" => "sample-alpha",
          "repo_beta" => "sample-beta"
        },
        agent_support_ref: "refs/heads/feature/prototype",
        agent_workspace_cleanup_policy: :cleanup_after_job
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::AgentWorkerGateway)
    builder = gateway.instance_variable_get(:@workspace_request_builder)
    repo_slot_policy = builder.instance_variable_get(:@repo_slot_policy)
    expect(repo_slot_policy.required_slots).to eq(%i[repo_alpha repo_beta])
    expect(builder.instance_variable_get(:@support_refs)).to include(default: "refs/heads/feature/prototype")
  end

  it "builds an agent materialized HTTP worker gateway with slot-specific support refs" do
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
          "repo_alpha" => "sample-alpha",
          "repo_beta" => "sample-beta"
        },
        agent_support_refs: {
          "repo_beta" => "refs/heads/support/beta"
        }
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::AgentWorkerGateway)
    builder = gateway.instance_variable_get(:@workspace_request_builder)
    expect(builder.instance_variable_get(:@support_refs)).to include(repo_beta: "refs/heads/support/beta")
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

  it "rejects remote HTTP for the agent HTTP worker gateway unless explicitly allowed" do
    expect do
      A3::CLI.send(
        :build_worker_gateway,
        options: {
          worker_gateway: "agent-http",
          worker_command: "ruby",
          worker_command_args: [],
          agent_control_plane_url: "http://a3.example.com:7393",
          agent_shared_workspace_mode: "same-path"
        },
        command_runner: instance_double(A3::Infra::LocalCommandRunner)
      )
    end.to raise_error(ArgumentError, /local topology/)
  end

  it "allows explicit diagnostic remote HTTP for the agent HTTP worker gateway" do
    gateway = A3::CLI.send(
      :build_worker_gateway,
      options: {
        worker_gateway: "agent-http",
        worker_command: "ruby",
        worker_command_args: [],
        agent_control_plane_url: "http://a3.example.com:7393",
        agent_shared_workspace_mode: "same-path",
        agent_allow_insecure_remote: true
      },
      command_runner: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(gateway).to be_a(A3::Infra::AgentWorkerGateway)
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
          "repo_alpha" => "sample-alpha"
        }
      },
      fallback: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(runner).to be_a(A3::Infra::AgentCommandRunner)
  end

  it "uses the fallback verification command runner when not configured" do
    fallback = instance_double(A3::Infra::LocalCommandRunner)

    runner = A3::CLI.send(
      :build_command_runner,
      options: { verification_command_runner: nil },
      fallback: fallback
    )

    expect(runner).to eq(fallback)
  end

  it "builds an agent HTTP merge runner when required options are provided" do
    runner = A3::CLI.send(
      :build_merge_runner,
      options: {
        merge_runner: "agent-http",
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_source_aliases: {
          "repo_alpha" => "sample-alpha"
        },
        worker_command: "a3-worker",
        worker_command_args: ["--run"],
        agent_env: {
          "A3_ENV" => "test"
        }
      },
      fallback: instance_double(A3::Infra::DisabledMergeRunner)
    )

    expect(runner).to be_a(A3::Infra::AgentMergeRunner)
    expect(runner.instance_variable_get(:@merge_recovery_command)).to eq("a3-worker")
    expect(runner.instance_variable_get(:@merge_recovery_args)).to eq(["--run"])
    expect(runner.instance_variable_get(:@merge_recovery_env)).to eq("A3_ENV" => "test")
  end

  it "requires source aliases for the agent HTTP merge runner" do
    expect do
      A3::CLI.send(
        :build_merge_runner,
        options: {
          merge_runner: "agent-http",
          agent_control_plane_url: "http://127.0.0.1:4567"
        },
        fallback: instance_double(A3::Infra::DisabledMergeRunner)
      )
    end.to raise_error(ArgumentError, /agent-source-alias/)
  end

  it "passes explicit agent env options to an agent HTTP verification command runner" do
    runner = A3::CLI.send(
      :build_command_runner,
      options: {
        verification_command_runner: "agent-http",
        agent_control_plane_url: "http://127.0.0.1:4567",
        agent_runtime_profile: "host-local",
        agent_shared_workspace_mode: "same-path",
        agent_env: {
          "A3_ROOT_DIR" => "/host/a3"
        }
      },
      fallback: instance_double(A3::Infra::LocalCommandRunner)
    )

    expect(runner.instance_variable_get(:@env)).to eq("A3_ROOT_DIR" => "/host/a3")
  end

  it "passes engine-managed agent environment options to verification and merge runners" do
    options = {
      agent_control_plane_url: "http://127.0.0.1:4567",
      agent_runtime_profile: "host-local",
      agent_shared_workspace_mode: "agent-materialized",
      agent_source_aliases: {
        "repo_alpha" => "sample-catalog-service"
      },
      agent_workspace_root: "/agent/workspaces",
      agent_source_paths: {
        "sample-catalog-service" => "/agent/repos/starters"
      }
    }

    command_runner = A3::CLI.send(
      :build_command_runner,
      options: options.merge(verification_command_runner: "agent-http"),
      fallback: instance_double(A3::Infra::LocalCommandRunner)
    )
    merge_runner = A3::CLI.send(
      :build_merge_runner,
      options: options.merge(merge_runner: "agent-http"),
      fallback: instance_double(A3::Infra::DisabledMergeRunner)
    )

    expect(command_runner.instance_variable_get(:@agent_environment)).to eq(
      "workspace_root" => "/agent/workspaces",
      "source_paths" => {
        "sample-catalog-service" => "/agent/repos/starters"
      }
    )
    expect(merge_runner.instance_variable_get(:@agent_environment)).to eq(command_runner.instance_variable_get(:@agent_environment))
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

  it "resolves a scoped control-plane auth token from a control token file" do
    Dir.mktmpdir do |dir|
      agent_token_path = File.join(dir, "agent-token")
      control_token_path = File.join(dir, "control-token")
      File.write(agent_token_path, "agent-token\n")
      File.write(control_token_path, "control-token\n")

      token = A3::CLI.send(
        :agent_control_auth_token,
        agent_token: "",
        agent_token_file: agent_token_path,
        agent_control_token: "",
        agent_control_token_file: control_token_path
      )

      expect(token).to eq("control-token")
    end
  end

  it "falls back to the agent auth token when no scoped control token is configured" do
    Dir.mktmpdir do |dir|
      agent_token_path = File.join(dir, "agent-token")
      File.write(agent_token_path, "agent-token\n")

      token = A3::CLI.send(
        :agent_control_auth_token,
        agent_token: "",
        agent_token_file: agent_token_path,
        agent_control_token: "",
        agent_control_token_file: ""
      )

      expect(token).to eq("agent-token")
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
