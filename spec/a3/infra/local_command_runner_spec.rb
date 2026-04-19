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
      ["ruby -e 'print ENV.fetch(\"A3_WORKER_REQUEST_PATH\")'"],
      workspace: workspace,
      env: { "A3_WORKER_REQUEST_PATH" => "/tmp/request.json" }
    )

    expect(result.success?).to be(true)
    expect(result.summary).to include("ruby -e 'print ENV.fetch(\"A3_WORKER_REQUEST_PATH\")' ok")
  end

  it "provides A3_ROOT_DIR when the caller does not inject it" do
    original = ENV.delete("A3_ROOT_DIR")
    begin
      Dir.chdir(tmpdir) do
        result = described_class.new.run(
          ["ruby -e 'print ENV.fetch(\"A3_ROOT_DIR\")'"],
          workspace: workspace
        )

        expect(result.success?).to be(true)
        expect(result.summary).to include("ruby -e 'print ENV.fetch(\"A3_ROOT_DIR\")' ok")
      end
    ensure
      ENV["A3_ROOT_DIR"] = original if original
    end
  end

  it "expands public command placeholders before execution" do
    result_path = File.join(tmpdir, "placeholder-result.txt")

    result = described_class.new.run(
      ["ruby -e 'File.write(ARGV.fetch(0), ARGV.fetch(1))' {{workspace_root}}/placeholder-result.txt {{a2o_root_dir}}"],
      workspace: workspace,
      env: { "A2O_ROOT_DIR" => "/opt/a2o-test" }
    )

    expect(result.success?).to be(true)
    expect(File.read(result_path)).to eq("/opt/a2o-test")
  end
end
