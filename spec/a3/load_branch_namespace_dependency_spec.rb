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

  it "loads register_completed_run without requiring a3/domain first" do
    assert_loads("a3/application/register_completed_run", "A3::Application::RegisterCompletedRun")
  end

  it "loads agent_workspace_request_builder without requiring a3/domain first" do
    assert_loads("a3/infra/agent_workspace_request_builder", "A3::Infra::AgentWorkspaceRequestBuilder")
  end
end
