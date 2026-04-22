# frozen_string_literal: true

require "digest"
require "json"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

RSpec.describe "A3 host install CLI" do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "installs host launcher binaries and a target-selecting wrapper" do
    package_dir = File.join(@tmp_dir, "packages")
    write_host_launcher(package_dir, "darwin-amd64", "darwin launcher\n")
    write_host_launcher(package_dir, "linux-arm64", "linux launcher\n")
    write_manifest(package_dir, target: "darwin-amd64")
    write_contract(package_dir, runtime_version: A3::VERSION, package_version: A3::VERSION)
    share_source_dir = File.join(@tmp_dir, "share-source")
    write_share_asset(share_source_dir, "docker/compose/a2o-soloboard.yml", "services: {}\n")
    output_dir = File.join(@tmp_dir, "out")
    share_dir = File.join(@tmp_dir, "share-out")
    out = StringIO.new

    with_env("A2O_SHARE_DIR" => share_source_dir) do
      A3::CLI.start(["host", "install", "--package-dir", package_dir, "--output-dir", output_dir, "--share-dir", share_dir, "--runtime-image", "example/a2o-engine:latest"], out: out)
    end

    expect(out.string).to include("host_launcher_installed output=#{File.join(output_dir, 'a2o')}")
    expect(out.string).to include("host_launcher_alias output=#{File.join(output_dir, 'a3')}")
    expect(out.string).to include("targets=darwin-amd64,linux-arm64")
    expect(out.string).to include("host_share_installed output=#{share_dir}")
    expect(out.string).to include("host_runtime_image=example/a2o-engine:latest")
    expect(File.read(File.join(output_dir, "a3-darwin-amd64"))).to eq("darwin launcher\n")
    expect(File.executable?(File.join(output_dir, "a3-darwin-amd64"))).to be(true)
    expect(File.read(File.join(output_dir, "a2o-darwin-amd64"))).to eq("darwin launcher\n")
    expect(File.executable?(File.join(output_dir, "a2o-darwin-amd64"))).to be(true)
    expect(File.read(File.join(output_dir, "a3-linux-arm64"))).to eq("linux launcher\n")
    expect(File.executable?(File.join(output_dir, "a3-linux-arm64"))).to be(true)
    expect(File.read(File.join(output_dir, "a2o-linux-arm64"))).to eq("linux launcher\n")
    expect(File.executable?(File.join(output_dir, "a2o-linux-arm64"))).to be(true)
    expect(File.read(File.join(output_dir, "a2o"))).to include("exec \"$binary\" \"$@\"")
    expect(File.executable?(File.join(output_dir, "a2o"))).to be(true)
    expect(File.read(File.join(output_dir, "a3"))).to include("exec \"$binary\" \"$@\"")
    expect(File.executable?(File.join(output_dir, "a3"))).to be(true)
    expect(File.read(File.join(share_dir, "docker/compose/a2o-soloboard.yml"))).to eq("services: {}\n")
    expect(File.read(File.join(share_dir, "runtime-image"))).to eq("example/a2o-engine:latest\n")
  end

  it "fails when no host launcher binaries exist" do
    package_dir = File.join(@tmp_dir, "empty")
    FileUtils.mkdir_p(package_dir)

    expect do
      A3::CLI.start(["host", "install", "--package-dir", package_dir, "--output-dir", File.join(@tmp_dir, "out")])
    end.to raise_error(A3::Domain::ConfigurationError, /host launcher binaries not found/)
  end

  it "fails host install when package compatibility targets a different runtime version" do
    package_dir = File.join(@tmp_dir, "packages")
    write_host_launcher(package_dir, "darwin-amd64", "darwin launcher\n")
    write_manifest(package_dir, target: "darwin-amd64")
    write_contract(package_dir, runtime_version: "9.9.9", package_version: A3::VERSION)

    expect do
      A3::CLI.start(["host", "install", "--package-dir", package_dir, "--output-dir", File.join(@tmp_dir, "out")])
    end.to raise_error(A3::Domain::ConfigurationError, /runtime compatibility mismatch/)
  end

  it "fails host install when the compatibility contract points to a missing manifest" do
    package_dir = File.join(@tmp_dir, "packages")
    write_host_launcher(package_dir, "darwin-amd64", "darwin launcher\n")
    write_contract(package_dir, runtime_version: A3::VERSION, package_version: A3::VERSION, archive_manifest: "missing.jsonl")

    expect do
      A3::CLI.start(["host", "install", "--package-dir", package_dir, "--output-dir", File.join(@tmp_dir, "out")])
    end.to raise_error(A3::Domain::ConfigurationError, /manifest not found for compatibility contract/)
  end

  def write_host_launcher(package_dir, target, body)
    target_dir = File.join(package_dir, target)
    FileUtils.mkdir_p(target_dir)
    path = File.join(target_dir, "a3")
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def write_manifest(package_dir, target:)
    goos, goarch = target.split("-", 2)
    archive = "a3-agent-dev-#{target}.tar.gz"
    path = File.join(package_dir, archive)
    tar_io = StringIO.new
    Gem::Package::TarWriter.new(tar_io) do |tar|
      tar.add_file("a3-agent", 0o755) { |entry| entry.write("agent\n") }
    end
    tar_io.rewind
    Zlib::GzipWriter.open(path) { |gzip| gzip.write(tar_io.string) }
    sha256 = Digest::SHA256.file(path).hexdigest
    File.write(
      File.join(package_dir, "release-manifest.jsonl"),
      JSON.generate("version" => A3::VERSION, "goos" => goos, "goarch" => goarch, "archive" => archive, "sha256" => sha256) + "\n"
    )
  end

  def write_contract(package_dir, runtime_version:, package_version:, archive_manifest: "release-manifest.jsonl")
    File.write(
      File.join(package_dir, "package-compatibility.json"),
      JSON.pretty_generate(
        "schema" => "a2o-agent-package-compatibility/v1",
        "package_version" => package_version,
        "runtime_version" => runtime_version,
        "archive_manifest" => archive_manifest,
        "launcher_layout" => "platform-bin-dir-v1"
      )
    )
  end

  def write_share_asset(root, relative_path, body)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end
end
