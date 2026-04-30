# frozen_string_literal: true

require "tmpdir"

RSpec.describe "scheduler task claim repositories" do
  repositories = {
    "in-memory" => lambda { |_dir|
      counter = 0
      A3::Infra::InMemorySchedulerTaskClaimRepository.new(
        claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
      )
    },
    "json" => lambda { |dir|
      counter = 0
      A3::Infra::JsonSchedulerTaskClaimRepository.new(
        File.join(dir, "claims.json"),
        claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
      )
    },
    "sqlite" => lambda { |dir|
      counter = 0
      A3::Infra::SqliteSchedulerTaskClaimRepository.new(
        File.join(dir, "claims.sqlite3"),
        claim_ref_generator: -> { counter += 1; "claim-#{counter}" }
      )
    }
  }

  repositories.each do |name, factory|
    context name do
      around do |example|
        Dir.mktmpdir do |dir|
          @repository = factory.call(dir)
          example.run
        end
      end

      it "claims, links, heartbeats, releases, and lists active claims" do
        claim = @repository.claim_task(
          project_key: "portal",
          task_ref: "Portal#1",
          phase: :implementation,
          parent_group_key: "single:Portal#1",
          claimed_by: "scheduler-1",
          claimed_at: "2026-04-30T00:00:00Z"
        )

        expect(@repository.fetch(claim.claim_ref)).to eq(claim)
        expect(@repository.active_claims(project_key: "portal").map(&:claim_ref)).to eq([claim.claim_ref])

        linked = @repository.link_run(claim_ref: claim.claim_ref, run_ref: "run-1")
        heartbeated = @repository.heartbeat(claim_ref: claim.claim_ref, heartbeat_at: "2026-04-30T00:00:10Z")
        released = @repository.release_claim(claim_ref: claim.claim_ref)

        expect(linked.run_ref).to eq("run-1")
        expect(heartbeated.heartbeat_at).to eq("2026-04-30T00:00:10Z")
        expect(released.state).to eq(:released)
        expect(@repository.active_claims(project_key: "portal")).to be_empty
      end

      it "rejects active task double claims" do
        @repository.claim_task(
          task_ref: "A2O#1",
          phase: :implementation,
          parent_group_key: "single:A2O#1",
          claimed_by: "scheduler-1",
          claimed_at: "2026-04-30T00:00:00Z"
        )

        expect do
          @repository.claim_task(
            task_ref: "A2O#1",
            phase: :implementation,
            parent_group_key: "single:A2O#1",
            claimed_by: "scheduler-2",
            claimed_at: "2026-04-30T00:00:01Z"
          )
        end.to raise_error(A3::Domain::SchedulerTaskClaimConflict)
      end

      it "rejects active parent group conflicts" do
        @repository.claim_task(
          task_ref: "A2O#2",
          phase: :implementation,
          parent_group_key: "parent-group:A2O#1",
          claimed_by: "scheduler-1",
          claimed_at: "2026-04-30T00:00:00Z"
        )

        expect do
          @repository.claim_task(
            task_ref: "A2O#3",
            phase: :implementation,
            parent_group_key: "parent-group:A2O#1",
            claimed_by: "scheduler-2",
            claimed_at: "2026-04-30T00:00:01Z"
          )
        end.to raise_error(A3::Domain::SchedulerTaskClaimConflict)
      end

      it "allows the same task ref in another project" do
        @repository.claim_task(
          project_key: "portal",
          task_ref: "A2O#1",
          phase: :implementation,
          parent_group_key: "single:A2O#1",
          claimed_by: "scheduler-1",
          claimed_at: "2026-04-30T00:00:00Z"
        )
        claim = @repository.claim_task(
          project_key: "docs",
          task_ref: "A2O#1",
          phase: :implementation,
          parent_group_key: "single:A2O#1",
          claimed_by: "scheduler-2",
          claimed_at: "2026-04-30T00:00:01Z"
        )

        expect(claim.project_key).to eq("docs")
      end

      it "marks active claims stale and removes them from active claims" do
        claim = @repository.claim_task(
          task_ref: "A2O#1",
          phase: :implementation,
          parent_group_key: "single:A2O#1",
          claimed_by: "scheduler-1",
          claimed_at: "2026-04-30T00:00:00Z"
        )

        stale = @repository.mark_claim_stale(claim_ref: claim.claim_ref, reason: "pid missing")

        expect(stale.state).to eq(:stale)
        expect(stale.stale_reason).to eq("pid missing")
        expect(@repository.active_claims).to be_empty
      end
    end
  end

end
