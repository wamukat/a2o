# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::ForceStopRun do
  it "cancels the current run, clears the task binding, marks agent jobs stale, and removes the workspace" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      agent_job_store = A3::Infra::JsonAgentJobStore.new(File.join(dir, "agent_jobs.json"))
      run = build_run(ref: "run-force", task_ref: "Sample#351", phase: :verification, workspace_kind: :runtime_workspace)

      run_repository.save(run)
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#351",
          kind: :single,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha],
          status: :verifying,
          current_run_ref: run.ref
        )
      )
      FileUtils.mkdir_p(File.join(dir, "workspaces", "Sample-351", "runtime_workspace"))
      agent_job_store.enqueue(agent_job_request("job-force", task_ref: "Sample#351", run_ref: run.ref))
      agent_job_store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-29T00:00:00Z")

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        agent_job_store: agent_job_store
      ).call_task(task_ref: "Sample#351")

      expect(result.already_terminal).to eq(false)
      expect(result.run.terminal_outcome).to eq(:cancelled)
      expect(result.task).to have_attributes(status: :verifying, current_run_ref: nil)
      expect(result.stopped_jobs.map(&:job_id)).to eq(["job-force"])
      expect(result.cleaned_paths).to eq([File.join(dir, "workspaces", "Sample-351", "runtime_workspace")])
      expect(File.directory?(File.join(dir, "workspaces", "Sample-351", "runtime_workspace"))).to eq(false)
      expect(run_repository.fetch("run-force").terminal_outcome).to eq(:cancelled)
      expect(task_repository.fetch("Sample#351").current_run_ref).to be_nil
      expect(agent_job_store.fetch("job-force")).to have_attributes(
        state: :stale,
        stale_reason: "force-stopped runtime run run-force"
      )
    end
  end

  it "force-stops by run ref when the task is still bound to that run" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      run = build_run(ref: "run-by-ref", task_ref: "Sample#46", phase: :implementation, workspace_kind: :ticket_workspace)

      run_repository.save(run)
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#46",
          kind: :single,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: run.ref
        )
      )

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir
      ).call_run(run_ref: "run-by-ref", outcome: :aborted)

      expect(result.run.terminal_outcome).to eq(:aborted)
      expect(result.task).to have_attributes(status: :in_progress, current_run_ref: nil)
    end
  end

  it "cleans parent-bound child workspaces through the provisioner layout" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::InMemoryTaskRepository.new
      run_repository = A3::Infra::InMemoryRunRepository.new
      run = build_run(ref: "run-child", task_ref: "Sample#202", phase: :implementation, workspace_kind: :ticket_workspace)
      child_workspace = File.join(dir, "workspaces", "Sample-201-parent", "children", "Sample-202", "ticket_workspace")
      unrelated_workspace = File.join(dir, "workspaces", "Sample-999-parent", "children", "Sample-202", "ticket_workspace")

      run_repository.save(run)
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#202",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: run.ref,
          parent_ref: "Sample#201"
        )
      )
      FileUtils.mkdir_p(child_workspace)
      FileUtils.mkdir_p(unrelated_workspace)

      result = described_class.new(
        task_repository: task_repository,
        run_repository: run_repository,
        storage_dir: dir,
        provisioner: A3::Infra::LocalWorkspaceProvisioner.new(base_dir: dir, repo_sources: {})
      ).call_task(task_ref: "Sample#202")

      expect(result.cleaned_paths).to contain_exactly(child_workspace)
      expect(File.directory?(child_workspace)).to eq(false)
      expect(File.directory?(unrelated_workspace)).to eq(true)
      expect(task_repository.fetch("Sample#202").current_run_ref).to be_nil
      expect(run_repository.fetch("run-child").terminal_outcome).to eq(:cancelled)
    end
  end

  it "rejects force-stopping a task without an active run" do
    task_repository = A3::Infra::InMemoryTaskRepository.new
    run_repository = A3::Infra::InMemoryRunRepository.new
    task_repository.save(A3::Domain::Task.new(ref: "Sample#idle", kind: :single, edit_scope: [:repo_alpha]))

    use_case = described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      storage_dir: Dir.tmpdir
    )

    expect { use_case.call_task(task_ref: "Sample#idle") }
      .to raise_error(A3::Domain::ConfigurationError, /has no active current_run_ref/)
  end

  def build_run(ref:, task_ref:, phase:, workspace_kind:)
    source_descriptor =
      if workspace_kind == :ticket_workspace
        A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: task_ref, ref: "refs/heads/a2o/work/#{task_ref.tr('#', '-')}")
      else
        A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: task_ref, ref: "refs/heads/a2o/work/#{task_ref.tr('#', '-')}")
      end

    A3::Domain::Run.new(
      ref: ref,
      task_ref: task_ref,
      phase: phase,
      workspace_kind: workspace_kind,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task_ref, owner_scope: :task, snapshot_version: source_descriptor.ref)
    )
  end

  def agent_job_request(job_id, task_ref:, run_ref:)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: task_ref,
      run_ref: run_ref,
      phase: :verification,
      runtime_profile: "host-local-agent",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: task_ref, ref: "refs/heads/a2o/work/#{task_ref.tr('#', '-')}"),
      working_dir: "/workspace/repo-alpha",
      command: "sh",
      args: ["-lc", "task test"],
      env: {},
      timeout_seconds: 1800,
      artifact_rules: []
    )
  end
end
