# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::LocalCommandRunner do
  let(:tmpdir) { Dir.mktmpdir("a3-v2-command-runner") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(tmpdir),
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/sample",
        task_ref: "A3-v2#3028"
      ),
      slot_paths: {}
    )
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "runs commands with injected environment variables" do
    result = described_class.new.run(
      ["ruby -e 'print ENV.fetch(\"A2O_WORKER_REQUEST_PATH\")'"],
      workspace: workspace,
      env: { "A2O_WORKER_REQUEST_PATH" => "/tmp/request.json" }
    )

    expect(result.success?).to be(true)
    expect(result.summary).to include("ruby -e 'print ENV.fetch(\"A2O_WORKER_REQUEST_PATH\")' ok")
  end

  it "provides A2O_ROOT_DIR when the caller does not inject it" do
    original = ENV.delete("A2O_ROOT_DIR")
    begin
      Dir.chdir(tmpdir) do
        result = described_class.new.run(
          ["ruby -e 'print ENV.fetch(\"A2O_ROOT_DIR\")'"],
          workspace: workspace
        )

        expect(result.success?).to be(true)
        expect(result.summary).to include("ruby -e 'print ENV.fetch(\"A2O_ROOT_DIR\")' ok")
      end
    ensure
      original ? ENV["A2O_ROOT_DIR"] = original : ENV.delete("A2O_ROOT_DIR")
    end
  end

  it "rejects legacy A3_ROOT_DIR when A2O_ROOT_DIR is absent" do
    original_public = ENV.delete("A2O_ROOT_DIR")
    original_legacy = ENV["A3_ROOT_DIR"]
    ENV["A3_ROOT_DIR"] = "/tmp/legacy-root"

    expect do
      described_class.new.run(["true"], workspace: workspace)
    end.to raise_error(
      KeyError,
      /removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR/
    )
  ensure
    original_public ? ENV["A2O_ROOT_DIR"] = original_public : ENV.delete("A2O_ROOT_DIR")
    original_legacy ? ENV["A3_ROOT_DIR"] = original_legacy : ENV.delete("A3_ROOT_DIR")
  end

  it "rejects explicit legacy A3_ROOT_DIR even when A2O_ROOT_DIR is available" do
    original_public = ENV["A2O_ROOT_DIR"]
    original_legacy = ENV.delete("A3_ROOT_DIR")
    ENV["A2O_ROOT_DIR"] = "/tmp/a2o-root"

    expect do
      described_class.new.run(["true"], workspace: workspace, env: { "A3_ROOT_DIR" => "/tmp/legacy-root" })
    end.to raise_error(
      KeyError,
      /removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR/
    )
  ensure
    original_public ? ENV["A2O_ROOT_DIR"] = original_public : ENV.delete("A2O_ROOT_DIR")
    original_legacy ? ENV["A3_ROOT_DIR"] = original_legacy : ENV.delete("A3_ROOT_DIR")
  end

  it "expands public command placeholders before execution" do
    workspace_root = File.join(tmpdir, "workspace with spaces; no shell")
    FileUtils.mkdir_p(workspace_root)
    prepared_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(workspace_root),
      source_descriptor: workspace.source_descriptor,
      slot_paths: {}
    )
    result_path = File.join(workspace_root, "placeholder-result.txt")
    a2o_root = File.join(tmpdir, "a2o root; no shell")

    result = described_class.new.run(
      ["ruby -e 'File.write(ARGV.fetch(0), ARGV.fetch(1))' {{workspace_root}}/placeholder-result.txt {{a2o_root_dir}}"],
      workspace: prepared_workspace,
      env: { "A2O_ROOT_DIR" => a2o_root }
    )

    expect(result.success?).to be(true)
    expect(File.read(result_path)).to eq(a2o_root)
  end
end
