# frozen_string_literal: true

RSpec.describe A3::Application::ExecuteUntilIdle do
  let(:execute_next_runnable_task) { instance_double(A3::Application::ExecuteNextRunnableTask) }
  let(:scheduler_cycle_journal) do
    A3::Application::SchedulerCycleJournal.new(
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store)
    )
  end
  let(:project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only,
        target_ref: "refs/heads/feature/prototype"
      )
    )
  end
  let(:scheduler_store) { A3::Infra::InMemorySchedulerStore.new }
  let(:quarantine_terminal_task_workspaces) { A3::Application::NullQuarantineTerminalTaskWorkspaces.new }
  let(:cleanup_terminal_task_workspaces) do
    instance_double(
      A3::Application::CleanupTerminalTaskWorkspaces,
      call: A3::Application::CleanupTerminalTaskWorkspaces::Result.new(cleaned: [], dry_run: false, statuses: [:done], scopes: %i[ticket_workspace runtime_workspace])
    )
  end

  subject(:use_case) do
    described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      cycle_journal: scheduler_cycle_journal,
      quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces,
      cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces
    )
  end

  it "executes runnable tasks until the queue becomes empty" do
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3031", kind: :child, edit_scope: [:repo_beta]),
        phase: :review,
        started_run: :started_2,
        execution_result: :result_2
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: nil,
        phase: nil,
        started_run: nil,
        execution_result: nil
      )
    )

    result = use_case.call(project_context: project_context)

    expect(result.executed_count).to eq(2)
    expect(result.executions.size).to eq(2)
    expect(result.executions.map(&:phase)).to eq(%i[implementation review])
    expect(result.stop_reason).to eq(:idle)
    expect(result.scheduler_cycle.executed_steps).to eq(
      [
        A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3030", phase: :implementation),
        A3::Domain::SchedulerCycleStep.new(task_ref: "A3-v2#3031", phase: :review)
      ]
    )
  end

  it "respects the max_steps guard" do
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      )
    )

    result = use_case.call(project_context: project_context, max_steps: 1)

    expect(result.executed_count).to eq(1)
    expect(result.idle_reached).to eq(false)
    expect(result.stop_reason).to eq(:max_steps)
  end

  context "with a real parent flow stack" do
    let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
    let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
    let(:scheduler_store) { A3::Infra::InMemorySchedulerStore.new }
    let(:state_repository) { A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store) }
    let(:cycle_repository) { A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store) }
    let(:quarantine_terminal_task_workspaces) { instance_double(A3::Application::QuarantineTerminalTaskWorkspaces) }
    let(:cleanup_terminal_task_workspaces) { instance_double(A3::Application::CleanupTerminalTaskWorkspaces) }
    let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }
    let(:worker_gateway) { instance_double("WorkerGateway") }
    let(:command_runner) { instance_double(A3::Infra::LocalCommandRunner) }
    let(:merge_runner) { instance_double("MergeRunner") }
    let(:run_id_sequence) { ["run-review", "run-verification", "run-merge"].dup }
    let(:run_id_generator) { -> { run_id_sequence.shift } }

    let(:task) do
      build_parent_task(
        ref: "A3-v2#3019",
        status: :todo,
        child_refs: %w[A3-v2#3020 A3-v2#3021]
      )
    end

    let(:child_done_one) do
      build_child_task(
        ref: "A3-v2#3020",
        edit_scope: [:repo_alpha],
        status: :done,
        parent_ref: task.ref
      )
    end

    let(:child_done_two) do
      build_child_task(
        ref: "A3-v2#3021",
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: task.ref
      )
    end

    let(:project_context) do
      A3::Domain::ProjectContext.new(
        surface: A3::Domain::ProjectSurface.new(
          implementation_skill: "skills/implementation/base.md",
          review_skill: "skills/review/base.md",
          verification_commands: ["commands/verify-all"],
          remediation_commands: ["commands/apply-remediation"],
          workspace_hook: "hooks/prepare-runtime.sh"
        ),
        merge_config: A3::Domain::MergeConfig.new(
          target: :merge_to_live,
          policy: :ff_only,
          target_ref: "refs/heads/live/main"
        )
      )
    end

    subject(:parent_flow_use_case) do
      start_phase = A3::Application::StartPhase.new(run_id_generator: run_id_generator)
      register_started_run = A3::Application::RegisterStartedRun.new(
        task_repository: task_repository,
        run_repository: run_repository
      )
      register_completed_run = A3::Application::RegisterCompletedRun.new(
        task_repository: task_repository,
        run_repository: run_repository,
        plan_next_phase: A3::Application::PlanNextPhase.new,
        integration_ref_readiness_checker: instance_double(
          A3::Infra::IntegrationRefReadinessChecker,
          check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a2o/parent/A3-v2-3022")
        )
      )
      build_scope_snapshot = A3::Application::BuildScopeSnapshot.new
      build_artifact_owner = A3::Application::BuildArtifactOwner.new
      schedule_next_run = A3::Application::ScheduleNextRun.new(
        plan_next_runnable_task: A3::Application::PlanNextRunnableTask.new(task_repository: task_repository),
        start_run: A3::Application::StartRun.new(
          start_phase: start_phase,
          register_started_run: register_started_run,
          task_repository: task_repository,
          prepare_workspace: prepare_workspace
        ),
        build_scope_snapshot: build_scope_snapshot,
        build_artifact_owner: build_artifact_owner,
        run_repository: run_repository,
        integration_ref_readiness_checker: instance_double(
          A3::Infra::IntegrationRefReadinessChecker,
          check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a2o/parent/A3-v2-3022")
        )
      )
      run_worker_phase = A3::Application::RunWorkerPhase.new(
        task_repository: task_repository,
        run_repository: run_repository,
        register_completed_run: register_completed_run,
        prepare_workspace: prepare_workspace,
        worker_gateway: worker_gateway,
        task_packet_builder: A3::Application::BuildWorkerTaskPacket.new(external_task_source: A3::Infra::NullExternalTaskSource.new)
      )
      run_verification = A3::Application::RunVerification.new(
        task_repository: task_repository,
        run_repository: run_repository,
        register_completed_run: register_completed_run,
        command_runner: command_runner,
        prepare_workspace: prepare_workspace
      )
      run_merge = A3::Application::RunMerge.new(
        task_repository: task_repository,
        run_repository: run_repository,
        register_completed_run: register_completed_run,
        build_merge_plan: A3::Application::BuildMergePlan.new(
          task_repository: task_repository,
          run_repository: run_repository
        ),
        merge_runner: merge_runner,
        prepare_workspace: prepare_workspace
      )
      scheduler_cycle_journal = A3::Application::SchedulerCycleJournal.new(
        scheduler_state_repository: state_repository,
        scheduler_cycle_repository: cycle_repository
      )
      execute_next = A3::Application::ExecuteNextRunnableTask.new(
        schedule_next_run: schedule_next_run,
        run_worker_phase: run_worker_phase,
        run_verification: run_verification,
        run_merge: run_merge
      )

      described_class.new(
        execute_next_runnable_task: execute_next,
        cycle_journal: scheduler_cycle_journal,
        quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces,
        cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces
      )
    end

    before do
      task_repository.save(child_done_one)
      task_repository.save(child_done_two)
      task_repository.save(task)
      allow(quarantine_terminal_task_workspaces).to receive(:call).and_return(
        A3::Application::QuarantineTerminalTaskWorkspaces::Result.new(quarantined: [])
      )
      allow(cleanup_terminal_task_workspaces).to receive(:call).and_return(
        A3::Application::CleanupTerminalTaskWorkspaces::Result.new(cleaned: [])
      )
      allow(prepare_workspace).to receive(:call) do |task:, phase:, source_descriptor:, scope_snapshot:, artifact_owner:, bootstrap_marker:|
        A3::Application::PrepareWorkspace::Result.new(
          workspace: A3::Domain::PreparedWorkspace.new(
            workspace_kind: source_descriptor.workspace_kind,
            root_path: "/tmp/#{task.ref}/#{phase}",
            source_descriptor: source_descriptor,
            slot_paths: {
              repo_alpha: "/tmp/#{task.ref}/#{phase}/repo-alpha",
              repo_beta: "/tmp/#{task.ref}/#{phase}/repo-beta"
            }
          )
        )
      end
      allow(worker_gateway).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(
          success: true,
          summary: "review completed",
          response_bundle: {
            "review_disposition" => {
              "kind" => "completed",
              "slot_scopes" => ["repo_alpha"],
              "summary" => "No findings",
              "description" => "Parent review completed without outstanding findings.",
              "finding_key" => "completed-no-findings"
            }
          }
        )
      )
      allow(command_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(success: true, summary: "verification completed")
      )
      allow(merge_runner).to receive(:run).and_return(
        A3::Application::ExecutionResult.new(success: true, summary: "merge completed")
      )
    end

    it "advances a parent task through review, verification, and merge until idle" do
      result = parent_flow_use_case.call(project_context: project_context)

      expect(result.executed_count).to eq(3)
      expect(result.stop_reason).to eq(:idle)
      expect(result.executions.map(&:phase)).to eq(%i[review verification merge])
      expect(result.scheduler_cycle.executed_steps).to eq(
        [
          A3::Domain::SchedulerCycleStep.new(task_ref: task.ref, phase: :review),
          A3::Domain::SchedulerCycleStep.new(task_ref: task.ref, phase: :verification),
          A3::Domain::SchedulerCycleStep.new(task_ref: task.ref, phase: :merge)
        ]
      )
      expect(task_repository.fetch(task.ref).status).to eq(:done)
      expect(run_repository.fetch("run-review").phase).to eq(:review)
      expect(run_repository.fetch("run-verification").phase).to eq(:verification)
      expect(run_repository.fetch("run-merge").phase).to eq(:merge)
    end
  end
end
