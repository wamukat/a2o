# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  it "shows aggregated operator state and repairs stale runs" do
    Dir.mktmpdir do |dir|
      out = StringIO.new

      described_class.start(
        ["pause-scheduler", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )

      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(ref: "Sample#1", kind: :single, edit_scope: [:repo_alpha], status: :in_progress, current_run_ref: "missing-run")
      )
      File.write(File.join(dir, "scheduler-shot.lock"), "999999")

      described_class.start(
        ["show-state", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )
      described_class.start(
        ["repair-runs", "--storage-backend", "json", "--storage-dir", dir, "--apply"],
        out: out
      )
      described_class.start(
        ["show-state", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("shot status=stale")
      expect(out.string).to include("repairable=stale_shot_lock,stale_run:Sample#1")
      expect(out.string).to include("repair-runs dry_run=false actions=2")
      expect(out.string).to include("repair stale_shot_lock target=- applied=true")
      expect(out.string).to include("repair stale_task_missing_run target=Sample#1 applied=true")
      expect(out.string).to include("active_runs=0")
    end
  end

  it "surfaces and repairs stale active runs whose workspace is missing" do
    Dir.mktmpdir do |dir|
      out = StringIO.new

      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))

      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-stale",
          task_ref: "Sample#3179",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.runtime_integration_record(task_ref: "Sample#3179", ref: "refs/heads/a2o/parent/Sample-3179"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: %i[repo_alpha repo_beta], verification_scope: %i[repo_alpha repo_beta], ownership_scope: :parent),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "Sample#3179", owner_scope: :parent, snapshot_version: "refs/heads/a2o/parent/Sample-3179")
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "Sample#3179",
          kind: :parent,
          edit_scope: %i[repo_alpha repo_beta],
          verification_scope: %i[repo_alpha repo_beta],
          status: :in_review,
          current_run_ref: "run-stale"
        )
      )

      described_class.start(
        ["show-state", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )
      described_class.start(
        ["repair-runs", "--storage-backend", "json", "--storage-dir", dir, "--apply"],
        out: out
      )
      described_class.start(
        ["show-state", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("run Sample#3179 run_ref=run-stale phase=review status=stale_workspace")
      expect(out.string).to include("repairable=stale_run:Sample#3179")
      expect(out.string).to include("repair stale_task_missing_workspace target=Sample#3179 applied=true")
      expect(out.string).to include("active_runs=0")
    end
  end

  it "shows active scheduler task claims" do
    Dir.mktmpdir do |dir|
      out = StringIO.new
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_claim_repository = A3::Infra::JsonSchedulerTaskClaimRepository.new(
        File.join(dir, "scheduler_task_claims.json"),
        claim_ref_generator: -> { "claim-visible" }
      )
      task_repository.save(
        A3::Domain::Task.new(ref: "Sample#418", kind: :single, edit_scope: [:repo_alpha], status: :in_progress)
      )
      task_claim_repository.claim_task(
        task_ref: "Sample#418",
        phase: :implementation,
        parent_group_key: "Sample#418",
        claimed_by: "scheduler-test",
        claimed_at: "2026-05-01T00:00:00Z"
      )

      described_class.start(
        ["show-state", "--storage-backend", "json", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("active_claims=1")
      expect(out.string).to include("claim Sample#418 claim_ref=claim-visible phase=implementation parent_group=Sample#418 run_ref=-")
    end
  end
end
