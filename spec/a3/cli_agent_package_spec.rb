# frozen_string_literal: true

require "digest"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

RSpec.describe "A3 agent package CLI" do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "lists packaged agent binaries" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive))
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION)
    out = StringIO.new

    A3::CLI.start(["agent", "package", "list", "--package-dir", @tmp_dir], out: out)

    expect(out.string).to include("agent_package_dir=#{@tmp_dir}")
    expect(out.string).to include("agent_package_contract schema=a2o-agent-package-compatibility/v1")
    expect(out.string).to include("target=linux-amd64")
  end

  it "exports the selected packaged agent binary" do
    archive = write_agent_archive(target: "darwin-arm64", body: "binary\n")
    write_manifest(target: "darwin-arm64", archive: File.basename(archive))
    output = File.join(@tmp_dir, "out", "a3-agent")
    out = StringIO.new

    A3::CLI.start(
      ["agent", "package", "export", "--package-dir", @tmp_dir, "--target", "darwin-arm64", "--output", output],
      out: out
    )

    expect(out.string).to include("agent_package_exported target=darwin-arm64")
    expect(File.read(output)).to eq("binary\n")
  end

  it "verifies packaged agent binaries" do
    archive = write_agent_archive(target: "linux-arm64")
    write_manifest(target: "linux-arm64", archive: File.basename(archive))
    out = StringIO.new

    A3::CLI.start(["agent", "package", "verify", "--package-dir", @tmp_dir], out: out)

    expect(out.string).to include("target=linux-arm64")
    expect(out.string).to include("ok=true")
  end

  it "fails export when the package contract targets a different runtime version" do
    archive = write_agent_archive(target: "linux-arm64")
    write_manifest(target: "linux-arm64", archive: File.basename(archive))
    write_contract(runtime_version: "9.9.9", package_version: A3::VERSION)

    expect do
      A3::CLI.start(["agent", "package", "export", "--package-dir", @tmp_dir, "--target", "linux-arm64", "--output", File.join(@tmp_dir, "out", "a3-agent")], out: StringIO.new)
    end.to raise_error(A3::Domain::ConfigurationError, /runtime compatibility mismatch/)
  end

  def write_agent_archive(target:, body: "agent-binary\n")
    archive_path = File.join(@tmp_dir, "a3-agent-dev-#{target}.tar.gz")
    tar_io = StringIO.new
    Gem::Package::TarWriter.new(tar_io) do |tar|
      tar.add_file("a3-agent", 0o755) { |entry| entry.write(body) }
    end
    tar_io.rewind
    Zlib::GzipWriter.open(archive_path) { |gzip| gzip.write(tar_io.string) }
    archive_path
  end

  def write_manifest(target:, archive:)
    goos, goarch = target.split("-", 2)
    sha256 = Digest::SHA256.file(File.join(@tmp_dir, archive)).hexdigest
    File.write(
      File.join(@tmp_dir, "release-manifest.jsonl"),
      JSON.generate("version" => A3::VERSION, "goos" => goos, "goarch" => goarch, "archive" => archive, "sha256" => sha256) + "\n"
    )
  end

  def write_contract(runtime_version:, package_version:)
    File.write(
      File.join(@tmp_dir, "package-compatibility.json"),
      JSON.pretty_generate(
        "schema" => "a2o-agent-package-compatibility/v1",
        "package_version" => package_version,
        "runtime_version" => runtime_version,
        "archive_manifest" => "release-manifest.jsonl",
        "launcher_layout" => "platform-bin-dir-v1"
      )
    )
  end
end
