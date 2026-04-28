# frozen_string_literal: true

RSpec.describe "A3 version" do
  it "matches the A2O 0.5.47 release version" do
    expect(A3::VERSION).to eq("0.5.47")
  end

  it "keeps release workflow version aligned" do
    workflow = File.read(File.expand_path("../../.github/workflows/publish-a2o-engine.yml", __dir__))

    expect(workflow).to include("A2O_RELEASE_VERSION: #{A3::VERSION}")
  end

  it "keeps runtime image defaults aligned" do
    dockerfile = File.read(File.expand_path("../../docker/a3-runtime/Dockerfile", __dir__))

    expect(dockerfile).to include("ARG A3_AGENT_VERSION=#{A3::VERSION}")
    expect(dockerfile).to include("ARG A3_IMAGE_VERSION=#{A3::VERSION}")
  end

  it "keeps gemspec version aligned" do
    gemspec = File.read(File.expand_path("../../a2o.gemspec", __dir__))

    expect(gemspec).to include(%(spec.version = "#{A3::VERSION}"))
  end

  it "keeps lockfile path spec version aligned" do
    lockfile = File.read(File.expand_path("../../Gemfile.lock", __dir__))

    expect(lockfile).to include("a2o (#{A3::VERSION})")
  end

  it "keeps bundled Kanbalone default image aligned with the documented release surface" do
    expected_image = "ghcr.io/wamukat/kanbalone:v0.9.22"
    repo_root = File.expand_path("../..", __dir__)
    release_compose = File.read(File.join(repo_root, "docker/compose/a2o-kanbalone.release.yml"))
    dev_compose = File.read(File.join(repo_root, "docker/compose/a2o-kanbalone.yml"))
    english_surface = File.read(File.join(repo_root, "docs/en/user/80-current-release-surface.md"))
    japanese_surface = File.read(File.join(repo_root, "docs/ja/user/80-current-release-surface.md"))

    expect(release_compose).to include("KANBALONE_IMAGE:-#{expected_image}")
    expect(dev_compose).to include("KANBALONE_IMAGE:-#{expected_image}")
    expect(english_surface).to include("Kanbalone `v0.9.22`")
    expect(japanese_surface).to include("Kanbalone イメージは `v0.9.22`")
  end
end
