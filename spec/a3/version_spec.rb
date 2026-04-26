# frozen_string_literal: true

RSpec.describe "A3 version" do
  it "matches the A2O 0.5.33 release version" do
    expect(A3::VERSION).to eq("0.5.33")
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
end
