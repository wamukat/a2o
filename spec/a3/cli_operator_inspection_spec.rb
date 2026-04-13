# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  def with_env(values)
    original = {}
    values.each do |key, value|
      original[key] = ENV.key?(key) ? ENV[key] : :__missing__
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    original.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  it "shows task and run inspection views through sqlite backend" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []\n")
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#parent",
          kind: :parent,
          edit_scope: %i[repo_alpha repo_beta],
          status: :in_review,
          child_refs: ["A3-v2#child"]
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#child",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta],
          status: :blocked,
          current_run_ref: "run-1",
          parent_ref: "A3-v2#parent"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-1",
          task_ref: "A3-v2#child",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#child"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#child",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#parent",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          terminal_outcome: :blocked
        ).append_blocked_diagnosis(
          A3::Domain::BlockedDiagnosis.new(
            task_ref: "A3-v2#child",
            run_ref: "run-1",
            phase: :review,
            outcome: :blocked,
            review_target: A3::Domain::ReviewTarget.new(
              base_commit: "base123",
              head_commit: "head456",
              task_ref: "A3-v2#child",
              phase_ref: :review
            ),
            source_descriptor: A3::Domain::SourceDescriptor.new(
              workspace_kind: :runtime_workspace,
              source_type: :detached_commit,
              ref: "head456",
              task_ref: "A3-v2#child"
            ),
            scope_snapshot: A3::Domain::ScopeSnapshot.new(
              edit_scope: [:repo_alpha],
              verification_scope: %i[repo_alpha repo_beta],
              ownership_scope: :task
            ),
            artifact_owner: A3::Domain::ArtifactOwner.new(
              owner_ref: "A3-v2#parent",
              owner_scope: :task,
              snapshot_version: "head456"
            ),
            expected_state: "runtime workspace available",
            observed_state: "repo-beta missing",
            failing_command: "codex exec --json -",
            diagnostic_summary: "review launch could not resolve runtime workspace",
            infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
          ),
          execution_record: A3::Domain::PhaseExecutionRecord.new(
            summary: "review launch could not resolve runtime workspace",
            failing_command: "codex exec --json -",
            observed_state: "repo-beta missing",
            diagnostics: {
              "missing_path" => "/tmp/repo-beta",
              "worker_response_bundle" => {
                "success" => false,
                "summary" => "review blocked",
                "failing_command" => "codex exec --json -",
                "observed_state" => "repo-beta missing"
              }
            },
            runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
              task_kind: :child,
              repo_scope: :repo_alpha,
              phase: :review,
              implementation_skill: "sample-implementation",
              review_skill: "sample-review",
              verification_commands: ["commands/check-style", "commands/verify-all"],
              remediation_commands: ["commands/apply-remediation"],
              workspace_hook: "sample-bootstrap",
              merge_target: :merge_to_parent,
              merge_policy: :ff_only
            )
          )
        )
      )

      out = StringIO.new
      described_class.start(["show-task", "--storage-backend", "sqlite", "--storage-dir", dir, "A3-v2#child"], out: out)
      described_class.start(["show-run", "--storage-backend", "sqlite", "--storage-dir", dir, "--preset-dir", preset_dir, "run-1", manifest_path], out: out)

      expect(out.string).to include("task A3-v2#child kind=child status=blocked current_run=run-1")
      expect(out.string).to include("runnable_reason=already_running")
      expect(out.string).to include("runnable_blocked_by=run-1")
      expect(out.string).to include("parent=A3-v2#parent status=in_review current_run=")
      expect(out.string).to include("run run-1 task=A3-v2#child phase=verification workspace=runtime_workspace source=detached_commit:head456 outcome=blocked")
      expect(out.string).to include("review_target=base123..head456")
      expect(out.string).to include("latest_execution phase=verification summary=review launch could not resolve runtime workspace")
      expect(out.string).to include("failing_command=codex exec --json -")
      expect(out.string).to include("observed_state=repo-beta missing")
      expect(out.string).to include("worker_response_bundle={\"success\"=>false, \"summary\"=>\"review blocked\", \"failing_command\"=>\"codex exec --json -\", \"observed_state\"=>\"repo-beta missing\"}")
      expect(out.string).to include("execution_diagnostic.missing_path=/tmp/repo-beta")
      expect(out.string).to include("runtime task_kind=child repo_scope=repo_alpha phase=verification")
      expect(out.string).to include("runtime review_skill=sample-review")
      expect(out.string).to include("runtime verification_commands=commands/check-style commands/verify-all")
      expect(out.string).to include("runtime remediation_commands=commands/apply-remediation")
      expect(out.string).to include("runtime merge_target=merge_to_parent merge_policy=ff_only")
      expect(out.string).to include("latest_blocked phase=verification summary=review launch could not resolve runtime workspace")
      expect(out.string).to include("blocked_expected=runtime workspace available")
      expect(out.string).to include("blocked_observed=repo-beta missing")
      expect(out.string).to include("blocked_diagnostic.missing_path=/tmp/repo-beta")
      expect(out.string).to include("recovery decision=requires_operator_action next_action=diagnose_blocked operator_action_required=true")
      expect(out.string).to include("rerun_hint=diagnose blocked state and choose a fresh rerun source")
    end
  end

  it "shows runtime package recovery commands when manifest context is provided" do
    with_env(
      "A3_SECRET" => "token",
      "A3_SCHEDULER_STORE_MIGRATION" => "pending"
    ) do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "manifest.yml")
        preset_dir = File.join(dir, "presets")
        repo_source_dir = File.join(dir, "repos", "repo-alpha")
        FileUtils.mkdir_p(preset_dir)
        FileUtils.mkdir_p(repo_source_dir)
        File.write(manifest_path, "schema_version: 1\npresets: []\n")

        task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
        run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
        task_repository.save(
          A3::Domain::Task.new(
            ref: "A3-v2#child",
            kind: :child,
            edit_scope: [:repo_alpha],
            verification_scope: %i[repo_alpha repo_beta],
            status: :blocked,
            current_run_ref: "run-1",
            parent_ref: "A3-v2#parent"
          )
        )
        run_repository.save(
          A3::Domain::Run.new(
            ref: "run-1",
            task_ref: "A3-v2#child",
            phase: :review,
            workspace_kind: :runtime_workspace,
            source_descriptor: A3::Domain::SourceDescriptor.new(
              workspace_kind: :runtime_workspace,
              source_type: :detached_commit,
              ref: "head456",
              task_ref: "A3-v2#child"
            ),
            scope_snapshot: A3::Domain::ScopeSnapshot.new(
              edit_scope: [:repo_alpha],
              verification_scope: %i[repo_alpha repo_beta],
              ownership_scope: :task
            ),
            review_target: A3::Domain::ReviewTarget.new(
              base_commit: "base123",
              head_commit: "head456",
              task_ref: "A3-v2#child",
              phase_ref: :review
            ),
            artifact_owner: A3::Domain::ArtifactOwner.new(
              owner_ref: "A3-v2#parent",
              owner_scope: :task,
              snapshot_version: "head456"
            ),
            terminal_outcome: :blocked
          )
        )

        out = StringIO.new
        described_class.start(
          [
            "show-run",
            "--storage-backend", "sqlite",
            "--storage-dir", dir,
            "--repo-source", "repo_alpha=#{repo_source_dir}",
            "--preset-dir", preset_dir,
            "run-1",
            manifest_path
          ],
          out: out
        )

        expect(out.string).to include("runtime_package_execution_modes=one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
        expect(out.string).to include("runtime_package_next_command=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
        expect(out.string).to include("runtime_package_migration_command=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
        expect(out.string).to include("runtime_package_runtime_validation_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} && bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
        expect(out.string).to include("runtime_package_startup_sequence=doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} migrate=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
        expect(out.string).to include("runtime_package_startup_blockers=scheduler_store_migration")
      end
    end
  end
end
