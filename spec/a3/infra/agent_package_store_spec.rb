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

  def write_manifest(target:, archive:, sha256: nil)
    goos, goarch = target.split("-", 2)
    sha256 ||= Digest::SHA256.file(File.join(@tmp_dir, archive)).hexdigest
    File.write(
      File.join(@tmp_dir, "release-manifest.jsonl"),
      JSON.generate("version" => "dev", "goos" => goos, "goarch" => goarch, "archive" => archive, "sha256" => sha256) + "\n"
    )
  end
end
