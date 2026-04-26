# frozen_string_literal: true

require "a3/cli/command_router"

RSpec.describe A3::CLI::CommandRouter do
  describe ".definition_for" do
    it "derives container dependency needs from session kind" do
      manifest = described_class.definition_for("show-project-surface")
      storage = described_class.definition_for("show-scheduler-state")
      runtime = described_class.definition_for("run-worker-phase")
      runtime_package = described_class.definition_for("doctor-runtime")

      expect(manifest.requires_container_dependencies?).to be(false)
      expect(storage.requires_container_dependencies?).to be(true)
      expect(runtime.requires_container_dependencies?).to be(true)
      expect(runtime_package.requires_container_dependencies?).to be(false)
    end
  end

  describe ".session_kind_for" do
    it "exposes explicit session kinds for storage, manifest, and runtime commands" do
      expect(described_class.session_kind_for("show-scheduler-state")).to eq(:storage)
      expect(described_class.session_kind_for("pause-scheduler")).to eq(:storage)
      expect(described_class.session_kind_for("recover-rerun")).to eq(:storage_runtime_package)
      expect(described_class.session_kind_for("reconcile-merge-recovery")).to eq(:storage)
      expect(described_class.session_kind_for("show-blocked-diagnosis")).to eq(:storage_runtime_package)
      expect(described_class.session_kind_for("show-run")).to eq(:storage_runtime_package)
      expect(described_class.session_kind_for("plan-next-decomposition-task")).to eq(:storage)
      expect(described_class.session_kind_for("run-decomposition-proposal-author")).to eq(:runtime)
      expect(described_class.session_kind_for("run-decomposition-proposal-review")).to eq(:runtime)
      expect(described_class.session_kind_for("show-decomposition-status")).to eq(:storage)
      expect(described_class.session_kind_for("skill-feedback-list")).to eq(:storage)
      expect(described_class.session_kind_for("skill-feedback-propose")).to eq(:storage)
      expect(described_class.session_kind_for("watch-summary")).to eq(:storage)
      expect(described_class.session_kind_for("clear-runtime-logs")).to eq(:storage)
      expect(described_class.session_kind_for("show-project-context")).to eq(:manifest)
      expect(described_class.session_kind_for("show-phase-runtime-config")).to eq(:manifest)
      expect(described_class.session_kind_for("execute-until-idle")).to eq(:runtime)
      expect(described_class.session_kind_for("run-worker-phase")).to eq(:runtime)
      expect(described_class.session_kind_for("doctor-runtime")).to eq(:runtime_package)
      expect(described_class.session_kind_for("show-runtime-package")).to eq(:runtime_package)
      expect(described_class.session_kind_for("migrate-scheduler-store")).to eq(:runtime_package)
      expect(described_class.session_kind_for("agent")).to eq(:agent_distribution)
      expect(described_class.session_kind_for("agent-server")).to eq(:agent_control)
      expect(described_class.session_kind_for("agent-artifact-cleanup")).to eq(:agent_control)
    end

    it "returns nil for unknown commands" do
      expect(described_class.session_kind_for("unknown-command")).to be_nil
    end
  end

  describe ".dispatch" do
    it "still dispatches known commands" do
      cli = Class.new do
        def handle_show_scheduler_state(argv, out:, **kwargs)
          out.puts("handled=#{argv.join(',')}")
        end
      end.new

      out = StringIO.new

      dispatched = described_class.dispatch(
        cli,
        command: "show-scheduler-state",
        argv: ["--storage-dir", "/tmp/a3"],
        out: out,
        run_id_generator: -> { "run-1" },
        command_runner: A3::Infra::LocalCommandRunner.new,
        merge_runner: A3::Infra::DisabledMergeRunner.new,
        worker_gateway: nil
      )

      expect(dispatched).to be(true)
      expect(out.string).to include("handled=--storage-dir,/tmp/a3")
    end

    it "dispatches manifest commands without injecting container dependencies" do
      cli = Class.new do
        def handle_show_project_surface(argv, out:)
          out.puts("manifest=#{argv.join(',')}")
        end
      end.new

      out = StringIO.new

      dispatched = described_class.dispatch(
        cli,
        command: "show-project-surface",
        argv: ["project.yaml"],
        out: out,
        run_id_generator: -> { "run-1" },
        command_runner: A3::Infra::LocalCommandRunner.new,
        merge_runner: A3::Infra::DisabledMergeRunner.new,
        worker_gateway: nil
      )

      expect(dispatched).to be(true)
      expect(out.string).to include("manifest=project.yaml")
    end

    it "dispatches runtime package commands without injecting container dependencies" do
      cli = Class.new do
        def handle_doctor_runtime(argv, out:)
          out.puts("runtime_package=#{argv.join(',')}")
        end
      end.new

      out = StringIO.new

      dispatched = described_class.dispatch(
        cli,
        command: "doctor-runtime",
        argv: ["project.yaml"],
        out: out,
        run_id_generator: -> { "run-1" },
        command_runner: A3::Infra::LocalCommandRunner.new,
        merge_runner: A3::Infra::DisabledMergeRunner.new,
        worker_gateway: nil
      )

      expect(dispatched).to be(true)
      expect(out.string).to include("runtime_package=project.yaml")
    end
  end
end
