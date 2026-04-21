# frozen_string_literal: true

RSpec.describe A3::Application::ScheduleNextRun do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:plan_next_runnable_task) { A3::Application::PlanNextRunnableTask.new(task_repository: task_repository) }
  let(:start_run) { instance_double(A3::Application::StartRun) }
  let(:build_scope_snapshot) { A3::Application::BuildScopeSnapshot.new }
  let(:build_artifact_owner) { A3::Application::BuildArtifactOwner.new }
  let(:integration_ref_readiness_checker) { instance_double(A3::Infra::IntegrationRefReadinessChecker, check: readiness_result) }
  let(:inherited_parent_state_resolver) { instance_double("InheritedParentStateResolver") }
  let(:upstream_line_guard) { A3::Domain::UpstreamLineGuard.new(inherited_parent_state_resolver: inherited_parent_state_resolver) }
  let(:readiness_result) do
    A3::Infra::IntegrationRefReadinessChecker::Result.new(
      ready: true,
      missing_slots: [],
      ref: "refs/heads/a2o/parent/A3-v2-3022"
    )
  end

  subject(:use_case) do
    described_class.new(
      plan_next_runnable_task: plan_next_runnable_task,
      start_run: start_run,
      build_scope_snapshot: build_scope_snapshot,
      build_artifact_owner: build_artifact_owner,
      run_repository: run_repository,
      integration_ref_readiness_checker: integration_ref_readiness_checker,
      upstream_line_guard: upstream_line_guard
    )
  end

  let(:task) do
    build_child_task(
      ref: "A3-v2#3030",
      edit_scope: [:repo_alpha],
      status: :todo,
      parent_ref: "A3-v2#3022"
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
        policy: :ff_only
      )
    )
  end

  before do
    allow(inherited_parent_state_resolver).to receive(:snapshot_for).and_return(nil)
    task_repository.save(task)
  end

  it "starts the next runnable implementation run with derived execution inputs" do
    expect(start_run).to receive(:call).with(
      task_ref: task.ref,
      phase: :implementation,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/A3-v2-3030",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/work/A3-v2-3030",
        head_commit: "refs/heads/a2o/work/A3-v2-3030",
        task_ref: task.ref,
        phase_ref: :implementation
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3030"
      ),
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::StartRun::Result.new(task: task, run: instance_double(A3::Domain::Run), workspace: instance_double(A3::Domain::PreparedWorkspace))
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to eq(task)
    expect(result.phase).to eq(:implementation)
  end

  it "starts recovery verification against the task-scoped verification source ref" do
    recovered_task = build_child_task(
      ref: task.ref,
      edit_scope: task.edit_scope,
      status: :verifying,
      parent_ref: task.parent_ref,
      verification_source_ref: "refs/heads/a2o/parent/A3-v2-3022"
    )
    task_repository.save(recovered_task)

    expect(start_run).to receive(:call).with(
      task_ref: recovered_task.ref,
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: recovered_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/parent/A3-v2-3022",
        head_commit: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: recovered_task.ref,
        phase_ref: :verification
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: recovered_task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/parent/A3-v2-3022"
      ),
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::StartRun::Result.new(task: recovered_task, run: instance_double(A3::Domain::Run), workspace: instance_double(A3::Domain::PreparedWorkspace))
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to eq(recovered_task)
    expect(result.phase).to eq(:verification)
  end

  it "does not start a new child implementation while a sibling is blocked on verification under the same parent line" do
    parent_ref = "refs/heads/a2o/parent/A3-v2-3022"
    verification_blocked_run = A3::Domain::Run.new(
      ref: "run-3031",
      task_ref: "A3-v2#3031",
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: parent_ref,
        task_ref: "A3-v2#3031"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "A3-v2#3031",
        run_ref: "run-3031",
        phase: :verification,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "A3-v2#3031",
          phase_ref: :verification
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: parent_ref,
          task_ref: "A3-v2#3031"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: %i[repo_alpha repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.parent_ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
        ),
        expected_state: "verification succeeds",
        observed_state: "lint failed on inherited parent line",
        failing_command: "commands/verify-all",
        diagnostic_summary: "verification failed",
        infra_diagnostics: {}
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "verification failed",
        diagnostics: {
          "inherited_parent_ref" => parent_ref,
          "inherited_parent_state_fingerprint" => "repo_alpha=parent-head-alpha-1|repo_beta=parent-head-beta-1"
        }
      )
    )
    allow(inherited_parent_state_resolver).to receive(:snapshot_for).with(
      task: task,
      phase: :implementation
    ).and_return(
      Struct.new(:ref, :heads_by_slot) do
        def fingerprint
          heads_by_slot.sort_by { |slot, _head| slot.to_s }.map { |slot, head| "#{slot}=#{head}" }.join("|")
        end
      end.new(parent_ref, { "repo_alpha" => "parent-head-alpha-1", "repo_beta" => "parent-head-beta-1" })
    )
    run_repository.save(verification_blocked_run)
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3031",
        edit_scope: [:repo_beta],
        status: :blocked,
        parent_ref: task.parent_ref
      )
    )

    expect(start_run).not_to receive(:call)

    result = use_case.call(project_context: project_context)

    expect(result.task).to be_nil
    expect(result.phase).to be_nil
    expect(result.started_run).to be_nil
  end

  it "does not resume child verification while a sibling is blocked on verification under the same parent line" do
    parent_ref = "refs/heads/a2o/parent/A3-v2-3022"
    verification_blocked_run = A3::Domain::Run.new(
      ref: "run-3031",
      task_ref: "A3-v2#3031",
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: parent_ref,
        task_ref: "A3-v2#3031"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.parent_ref,
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
      ),
      terminal_outcome: :blocked
    ).append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "A3-v2#3031",
        run_ref: "run-3031",
        phase: :verification,
        outcome: :blocked,
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base",
          head_commit: "head",
          task_ref: "A3-v2#3031",
          phase_ref: :verification
        ),
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: parent_ref,
          task_ref: "A3-v2#3031"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_beta],
          verification_scope: %i[repo_alpha repo_beta],
          ownership_scope: :task
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: task.parent_ref,
          owner_scope: :task,
          snapshot_version: "refs/heads/a2o/work/A3-v2-3031"
        ),
        expected_state: "verification succeeds",
        observed_state: "lint failed on inherited parent line",
        failing_command: "commands/verify-all",
        diagnostic_summary: "verification failed",
        infra_diagnostics: {}
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "verification failed",
        diagnostics: {
          "inherited_parent_ref" => parent_ref,
          "inherited_parent_state_fingerprint" => "repo_alpha=parent-head-alpha-1|repo_beta=parent-head-beta-1"
        }
      )
    )
    allow(inherited_parent_state_resolver).to receive(:snapshot_for).with(
      task: have_attributes(ref: "A3-v2#3030"),
      phase: :verification
    ).and_return(
      Struct.new(:ref, :heads_by_slot) do
        def fingerprint
          heads_by_slot.sort_by { |slot, _head| slot.to_s }.map { |slot, head| "#{slot}=#{head}" }.join("|")
        end
      end.new(parent_ref, { "repo_alpha" => "parent-head-alpha-1", "repo_beta" => "parent-head-beta-1" })
    )
    run_repository.save(verification_blocked_run)
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3030",
        edit_scope: [:repo_alpha],
        status: :verifying,
        parent_ref: task.parent_ref,
        verification_source_ref: parent_ref
      )
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3031",
        edit_scope: [:repo_beta],
        status: :blocked,
        parent_ref: task.parent_ref
      )
    )

    expect(start_run).not_to receive(:call)

    result = use_case.call(project_context: project_context)

    expect(result.task).to be_nil
    expect(result.phase).to be_nil
    expect(result.started_run).to be_nil
  end

  it "does not schedule legacy child review tasks" do
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    review_task = build_child_task(
      ref: "A3-v2#3032",
      edit_scope: [:repo_alpha],
      status: :in_review,
      parent_ref: "A3-v2#3022"
    )
    task_repository.save(review_task)

    expect(start_run).not_to receive(:call)

    result = use_case.call(project_context: project_context)

    expect(result.task).to be_nil
    expect(result.phase).to be_nil
  end

  it "starts the next runnable parent review run against the parent integration branch" do
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    parent_task = build_parent_task(
      ref: "A3-v2#3022",
      status: :todo,
      child_refs: %w[A3-v2#3030 A3-v2#3032]
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3032",
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: parent_task.ref
      )
    )
    task_repository.save(parent_task)

    expect(start_run).to receive(:call).with(
      task_ref: parent_task.ref,
      phase: :review,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/parent/A3-v2-3022",
        head_commit: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "refs/heads/a2o/parent/A3-v2-3022"
      ),
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::StartRun::Result.new(task: parent_task, run: instance_double(A3::Domain::Run), workspace: instance_double(A3::Domain::PreparedWorkspace))
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to eq(parent_task)
    expect(result.phase).to eq(:review)
  end

  it "fails fast before starting a parent run when the integration ref is missing for any slot" do
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3032",
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3022"
      )
    )
    parent_task = build_parent_task(
      ref: "A3-v2#3022",
      status: :todo,
      child_refs: %w[A3-v2#3030 A3-v2#3032]
    )
    task_repository.save(parent_task)
    allow(integration_ref_readiness_checker).to receive(:check).and_return(
      A3::Infra::IntegrationRefReadinessChecker::Result.new(
        ready: false,
        missing_slots: [:repo_alpha],
        ref: "refs/heads/a2o/parent/A3-v2-3022"
      )
    )

    expect(start_run).not_to receive(:call)

    expect { use_case.call(project_context: project_context) }
      .to raise_error(A3::Domain::ConfigurationError, /missing integration ref refs\/heads\/a2o\/parent\/A3-v2-3022 for slots repo_alpha/)
  end

  it "starts the next runnable parent verification run against the parent integration branch" do
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3032",
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3022"
      )
    )
    parent_task = build_parent_task(
      ref: "A3-v2#3022",
      status: :verifying,
      child_refs: %w[A3-v2#3030 A3-v2#3032]
    )
    task_repository.save(parent_task)

    expect(start_run).to receive(:call).with(
      task_ref: parent_task.ref,
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/parent/A3-v2-3022",
        head_commit: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref,
        phase_ref: :verification
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "refs/heads/a2o/parent/A3-v2-3022"
      ),
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::StartRun::Result.new(task: parent_task, run: instance_double(A3::Domain::Run), workspace: instance_double(A3::Domain::PreparedWorkspace))
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to eq(parent_task)
    expect(result.phase).to eq(:verification)
  end

  it "starts the next runnable parent merge run against the parent integration branch" do
    task_repository.save(
      build_child_task(
        ref: task.ref,
        edit_scope: task.edit_scope,
        status: :done,
        parent_ref: task.parent_ref
      )
    )
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3032",
        edit_scope: [:repo_beta],
        status: :done,
        parent_ref: "A3-v2#3022"
      )
    )
    parent_task = build_parent_task(
      ref: "A3-v2#3022",
      status: :merging,
      child_refs: %w[A3-v2#3030 A3-v2#3032]
    )
    task_repository.save(parent_task)

    expect(start_run).to receive(:call).with(
      task_ref: parent_task.ref,
      phase: :merge,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/parent/A3-v2-3022",
        head_commit: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref,
        phase_ref: :merge
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "refs/heads/a2o/parent/A3-v2-3022"
      ),
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::StartRun::Result.new(task: parent_task, run: instance_double(A3::Domain::Run), workspace: instance_double(A3::Domain::PreparedWorkspace))
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to eq(parent_task)
    expect(result.phase).to eq(:merge)
  end

  it "returns nil when no runnable task exists" do
    task_repository.save(
      build_child_task(
        ref: "A3-v2#3031",
        edit_scope: [:repo_beta],
        status: :in_progress,
        current_run_ref: "run-1",
        parent_ref: "A3-v2#3022"
      )
    )

    result = use_case.call(project_context: project_context)

    expect(result.task).to be_nil
    expect(result.phase).to be_nil
    expect(result.started_run).to be_nil
  end
end
