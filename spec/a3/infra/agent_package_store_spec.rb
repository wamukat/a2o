# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "zlib"

RSpec.describe A3::Infra::AgentPackageStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmp_dir = dir
      example.run
    end
  end

  it "lists packages from the release manifest" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive))

    packages = described_class.new(package_dir: @tmp_dir).list

    expect(packages.map(&:target)).to eq(["linux-amd64"])
    expect(packages.fetch(0).archive).to eq(File.basename(archive))
  end

  it "reads the package compatibility contract when present" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive))
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION)

    contract = described_class.new(package_dir: @tmp_dir).contract

    expect(contract.schema).to eq("a2o-agent-package-compatibility/v1")
    expect(contract.runtime_version).to eq(A3::VERSION)
    expect(contract.package_version).to eq(A3::VERSION)
  end

  it "verifies release archive checksums" do
    archive = write_agent_archive(target: "darwin-arm64")
    write_manifest(target: "darwin-arm64", archive: File.basename(archive))

    results = described_class.new(package_dir: @tmp_dir).verify(target: "darwin-arm64")

    expect(results.fetch(0)).to include(target: "darwin-arm64", ok: true)
  end

  it "exports an executable a3-agent binary from the selected archive" do
    archive = write_agent_archive(target: "linux-arm64", body: "#!/bin/sh\necho agent\n")
    write_manifest(target: "linux-arm64", archive: File.basename(archive))
    output = File.join(@tmp_dir, "bin", "a3-agent")

    result = described_class.new(package_dir: @tmp_dir).export(target: "linux/arm64", output: output)

    expect(result).to include(target: "linux-arm64", output: output)
    expect(File.read(output)).to eq("#!/bin/sh\necho agent\n")
    expect(File.executable?(output)).to be(true)
  end

  it "fails export when the checksum does not match" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive), sha256: "0" * 64)

    expect do
      described_class.new(package_dir: @tmp_dir).export(target: "linux-amd64", output: File.join(@tmp_dir, "a3-agent"))
    end.to raise_error(A3::Domain::ConfigurationError, /checksum mismatch/)
  end

  it "fails when the contract runtime version does not match the consuming runtime" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive))
    write_contract(runtime_version: "9.9.9", package_version: A3::VERSION)

    expect do
      described_class.new(package_dir: @tmp_dir).verify(target: "linux-amd64")
    end.to raise_error(A3::Domain::ConfigurationError, /runtime compatibility mismatch/)
  end

  it "fails when the contract package version disagrees with the manifest version" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive))
    write_contract(runtime_version: A3::VERSION, package_version: "9.9.9")

    expect do
      described_class.new(package_dir: @tmp_dir).verify(target: "linux-amd64")
    end.to raise_error(A3::Domain::ConfigurationError, /contract mismatch/)
  end

  it "honors a non-default archive manifest path from the contract" do
    archive = write_agent_archive(target: "linux-amd64")
    write_manifest(target: "linux-amd64", archive: File.basename(archive), manifest_name: "alternate-manifest.jsonl")
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION, archive_manifest: "alternate-manifest.jsonl")

    packages = described_class.new(package_dir: @tmp_dir).list

    expect(packages.map(&:target)).to eq(["linux-amd64"])
  end

  it "falls back to an externally published bundle when the local package dir has only a publication descriptor" do
    bundle_path = write_publication_bundle(target: "darwin-arm64", body: "#!/bin/sh\necho external\n")
    write_publication(bundle_path: bundle_path)
    output = File.join(@tmp_dir, "bin", "a3-agent")

    result = described_class.new(package_dir: @tmp_dir).export(target: "darwin-arm64", output: output)

    expect(result).to include(target: "darwin-arm64")
    expect(File.read(output)).to eq("#!/bin/sh\necho external\n")
  end

  it "falls back to an externally published bundle when the local manifest exists but archives are not embedded" do
    bundle_path = write_publication_bundle(target: "linux-amd64", body: "#!/bin/sh\necho external linux\n")
    write_publication(bundle_path: bundle_path)
    File.write(
      File.join(@tmp_dir, "release-manifest.jsonl"),
      JSON.generate("version" => A3::VERSION, "goos" => "linux", "goarch" => "amd64", "archive" => "a3-agent-dev-linux-amd64.tar.gz", "sha256" => "placeholder") + "\n"
    )
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION)
    output = File.join(@tmp_dir, "bin", "a3-agent")

    result = described_class.new(package_dir: @tmp_dir).export(target: "linux/amd64", output: output)

    expect(result).to include(target: "linux-amd64")
    expect(File.read(output)).to eq("#!/bin/sh\necho external linux\n")
  end

  it "verifies the effective external publication set when the local package dir is incomplete" do
    bundle_path = write_publication_bundle(target: "darwin-arm64", body: "#!/bin/sh\necho darwin external\n")
    write_publication(bundle_path: bundle_path)
    File.write(
      File.join(@tmp_dir, "release-manifest.jsonl"),
      JSON.generate("version" => A3::VERSION, "goos" => "linux", "goarch" => "amd64", "archive" => "a3-agent-dev-linux-amd64.tar.gz", "sha256" => "placeholder") + "\n"
    )
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION)

    results = described_class.new(package_dir: @tmp_dir).verify

    expect(results).to contain_exactly(include(target: "darwin-arm64", ok: true))
  end

  it "fails verification when the external publication bundle is incompatible even if the local embedded manifest matches" do
    bundle_path = write_publication_bundle(target: "darwin-arm64", body: "#!/bin/sh\necho darwin external\n", runtime_version: "9.9.9")
    write_publication(bundle_path: bundle_path)
    File.write(
      File.join(@tmp_dir, "release-manifest.jsonl"),
      JSON.generate("version" => A3::VERSION, "goos" => "linux", "goarch" => "amd64", "archive" => "a3-agent-dev-linux-amd64.tar.gz", "sha256" => "placeholder") + "\n"
    )
    write_contract(runtime_version: A3::VERSION, package_version: A3::VERSION)

    expect do
      described_class.new(package_dir: @tmp_dir).verify
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

  def write_manifest(target:, archive:, sha256: nil, manifest_name: "release-manifest.jsonl")
    goos, goarch = target.split("-", 2)
    sha256 ||= Digest::SHA256.file(File.join(@tmp_dir, archive)).hexdigest
    File.write(
      File.join(@tmp_dir, manifest_name),
      JSON.generate("version" => A3::VERSION, "goos" => goos, "goarch" => goarch, "archive" => archive, "sha256" => sha256) + "\n"
    )
  end

  def write_contract(runtime_version:, package_version:, archive_manifest: "release-manifest.jsonl")
    File.write(
      File.join(@tmp_dir, "package-compatibility.json"),
      JSON.pretty_generate(
        "schema" => "a2o-agent-package-compatibility/v1",
        "package_version" => package_version,
        "runtime_version" => runtime_version,
        "archive_manifest" => archive_manifest,
        "launcher_layout" => "platform-bin-dir-v1"
      )
    )
  end

  def write_publication(bundle_path:)
    File.write(
      File.join(@tmp_dir, "package-publication.json"),
      JSON.pretty_generate(
        "schema" => "a2o-agent-package-publication/v1",
        "version" => A3::VERSION,
        "bundle_archive" => File.basename(bundle_path),
        "bundle_url" => "file://#{bundle_path}",
        "bundle_archive_sha256" => Digest::SHA256.file(bundle_path).hexdigest,
        "compatibility_contract" => "package-compatibility.json",
        "archive_manifest" => "release-manifest.jsonl",
        "checksums_file" => "checksums.txt",
        "package_source_hint" => "github-release-assets"
      )
    )
  end

  def write_publication_bundle(target:, body:, runtime_version: A3::VERSION)
    bundle_root = File.join(@tmp_dir, "bundle-root")
    FileUtils.mkdir_p(bundle_root)
    archive = File.join(bundle_root, "a3-agent-dev-#{target}.tar.gz")
    tar_io = StringIO.new
    Gem::Package::TarWriter.new(tar_io) do |tar|
      tar.add_file("a3-agent", 0o755) { |entry| entry.write(body) }
    end
    tar_io.rewind
    Zlib::GzipWriter.open(archive) { |gzip| gzip.write(tar_io.string) }
    target_dir = File.join(bundle_root, target)
    FileUtils.mkdir_p(target_dir)
    File.write(File.join(target_dir, "a3"), body)
    FileUtils.chmod(0o755, File.join(target_dir, "a3"))
    manifest_path = File.join(bundle_root, "release-manifest.jsonl")
    goos, goarch = target.split("-", 2)
    File.write(
      manifest_path,
      JSON.generate("version" => A3::VERSION, "goos" => goos, "goarch" => goarch, "archive" => File.basename(archive), "sha256" => Digest::SHA256.file(archive).hexdigest) + "\n"
    )
    File.write(
      File.join(bundle_root, "package-compatibility.json"),
      JSON.pretty_generate(
        "schema" => "a2o-agent-package-compatibility/v1",
        "package_version" => A3::VERSION,
        "runtime_version" => runtime_version,
        "archive_manifest" => "release-manifest.jsonl",
        "launcher_layout" => "platform-bin-dir-v1"
      )
    )
    File.write(File.join(bundle_root, "checksums.txt"), "#{Digest::SHA256.file(File.join(bundle_root, File.basename(archive))).hexdigest}  #{File.basename(archive)}\n")

    bundle_path = File.join(@tmp_dir, "a2o-agent-packages-#{A3::VERSION}.tar.gz")
    tar_io = StringIO.new
    Gem::Package::TarWriter.new(tar_io) do |tar|
      add_path_to_tar(tar, bundle_root, "checksums.txt")
      add_path_to_tar(tar, bundle_root, "release-manifest.jsonl")
      add_path_to_tar(tar, bundle_root, "package-compatibility.json")
      add_path_to_tar(tar, bundle_root, File.basename(archive))
      add_path_to_tar(tar, bundle_root, File.join(target, "a3"))
    end
    tar_io.rewind
    Zlib::GzipWriter.open(bundle_path) { |gzip| gzip.write(tar_io.string) }
    bundle_path
  end

  def add_path_to_tar(tar, root, relative_path)
    full_path = File.join(root, relative_path)
    body = File.binread(full_path)
    mode = File.stat(full_path).mode & 0o777
    tar.add_file(relative_path, mode) { |entry| entry.write(body) }
  end
end
