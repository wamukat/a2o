# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe A3::Application::RunObserverHooks do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A2O#284",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :blocked,
      parent_ref: "A2O#280"
    )
  end

  let(:run) do
    base_run = A3::Domain::Run.new(
      ref: "run-284",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/284",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base",
        head_commit: "head",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "head"
      )
    )
    execution_record = A3::Domain::PhaseExecutionRecord.new(
      summary: "worker result schema invalid",
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result",
      diagnostics: { "validation_errors" => ["missing summary"] }
    )
    base_run.append_phase_evidence(
      phase: :review,
      source_descriptor: base_run.source_descriptor,
      scope_snapshot: base_run.scope_snapshot,
      execution_record: execution_record
    ).complete(outcome: :blocked)
  end

  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: @tmpdir,
      source_descriptor: run.source_descriptor,
      slot_paths: { repo_alpha: @tmpdir }
    )
  end

  it "invokes matching hooks with a JSON event path and records command output" do
    observed_path = File.join(@tmpdir, "observed.json")
    runtime = runtime_with_observers(
      hooks: [
        A3::Domain::ObserverConfig::Hook.new(
          event: "task.blocked",
          command: [
            "ruby",
            "-rjson",
            "-e",
            "payload = JSON.parse(File.read(ENV.fetch('A2O_OBSERVER_EVENT_PATH'))); File.write(ARGV.fetch(0), JSON.generate(payload)); puts 'notified'",
            observed_path
          ]
        )
      ]
    )

    result = described_class.new.call(
      events: ["task.blocked"],
      task: task,
      run: run,
      runtime: runtime,
      workspace: workspace
    )

    observed = JSON.parse(File.read(observed_path))
    expect(observed).to include(
      "schema" => "a2o.observer/v1",
      "event" => "task.blocked",
      "task_ref" => "A2O#284",
      "task_kind" => "child",
      "status" => "blocked",
      "run_ref" => "run-284",
      "phase" => "review",
      "summary" => "worker result schema invalid"
    )
    expect(result.hook_results.first).to include(
      "event" => "task.blocked",
      "success" => true,
      "exit_status" => 0,
      "stdout" => "notified\n"
    )
    expect(result.run.phase_records.last.execution_record.diagnostics.fetch("observer_hooks").first)
      .to include("event" => "task.blocked", "success" => true)
  end

  it "does not invoke hooks for unmatched events" do
    runtime = runtime_with_observers(
      hooks: [
        A3::Domain::ObserverConfig::Hook.new(
          event: "task.completed",
          command: ["ruby", "-e", "raise 'unexpected'"]
        )
      ]
    )

    result = described_class.new.call(
      events: ["task.blocked"],
      task: task,
      run: run,
      runtime: runtime,
      workspace: workspace
    )

    expect(result.hook_results).to eq([])
    expect(result.run).to eq(run)
  end

  it "records command runner errors without failing the phase" do
    runner = Class.new do
      def run(*)
        raise A3::Domain::ConfigurationError, "observer workspace unavailable"
      end
    end.new
    runtime = runtime_with_observers(
      hooks: [
        A3::Domain::ObserverConfig::Hook.new(
          event: "task.blocked",
          command: ["notify", "--event"]
        )
      ]
    )

    result = described_class.new(command_runner: runner).call(
      events: ["task.blocked"],
      task: task,
      run: run,
      runtime: runtime,
      workspace: workspace
    )

    expect(result.hook_results.first).to include(
      "success" => false,
      "exit_status" => nil,
      "stdout" => "",
      "stderr" => include("observer workspace unavailable")
    )
    expect(result.run.phase_records.last.execution_record.diagnostics.fetch("observer_hooks").first)
      .to include("success" => false)
  end

  it "passes observer payload through the worker protocol request for agent-owned workspaces" do
    runner = Class.new do
      attr_reader :call

      def agent_owned_workspace?
        true
      end

      def run(commands, workspace:, env:, task:, run:, command_intent:, worker_protocol_request:)
        @call = {
          commands: commands,
          workspace: workspace,
          env: env,
          task: task,
          run: run,
          command_intent: command_intent,
          worker_protocol_request: worker_protocol_request
        }
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "notify ok",
          diagnostics: { "stdout" => "agent notified\n", "stderr" => "" }
        )
      end
    end.new
    runtime = runtime_with_observers(
      hooks: [
        A3::Domain::ObserverConfig::Hook.new(
          event: "task.blocked",
          command: ["notify", "--event"]
        )
      ]
    )

    result = described_class.new(command_runner: runner).call(
      events: ["task.blocked"],
      task: task,
      run: run,
      runtime: runtime,
      workspace: workspace
    )

    expect(runner.call.fetch(:commands)).to eq(["A2O_OBSERVER_EVENT_PATH=\"$A2O_WORKER_REQUEST_PATH\" notify --event"])
    expect(runner.call.fetch(:env)).to eq({})
    expect(runner.call.fetch(:command_intent)).to eq(:observer)
    expect(runner.call.fetch(:worker_protocol_request)).to include(
      "schema" => "a2o.observer/v1",
      "event" => "task.blocked",
      "task_ref" => "A2O#284"
    )
    expect(result.hook_results.first).to include(
      "payload_path" => "$A2O_WORKER_REQUEST_PATH",
      "stdout" => "agent notified\n"
    )
  end

  def runtime_with_observers(hooks:)
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :repo_alpha,
      phase: :review,
      implementation_skill: "skills/implementation/base.md",
      review_skill: "skills/review/base.md",
      verification_commands: [],
      remediation_commands: [],
      metrics_collection_commands: [],
      observer_config: A3::Domain::ObserverConfig.new(hooks: hooks),
      workspace_hook: nil,
      merge_target: :merge_to_parent,
      merge_policy: :ff_only
    )
  end
end
