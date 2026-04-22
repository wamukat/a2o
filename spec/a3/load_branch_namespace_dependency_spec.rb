# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "branch namespace dependency loading" do
  def assert_loads(feature, constant_name)
    command = [
      RbConfig.ruby,
      "-Ilib",
      "-e",
      "require #{feature.inspect}; puts #{constant_name}"
    ]
    stdout, stderr, status = Open3.capture3(*command, chdir: File.expand_path("../..", __dir__))
    expect(status.success?).to be(true), stderr
    expect(stdout).to include(constant_name)
  end

  it "loads a3/application without requiring a3/domain first" do
    assert_loads("a3/application", "A3::Application::RegisterCompletedRun")
  end
end
