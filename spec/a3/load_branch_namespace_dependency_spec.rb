# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "branch namespace dependency loading" do
  def assert_script(source)
    command = [
      RbConfig.ruby,
      "-Ilib",
      "-e",
      source
    ]
    stdout, stderr, status = Open3.capture3(*command, chdir: File.expand_path("../..", __dir__))
    expect(status.success?).to be(true), stderr
    stdout
  end

  it "loads a3/application without requiring a3/domain first" do
    stdout = assert_script('require "a3/application"; puts A3::Application::RegisterCompletedRun')
    expect(stdout).to include("A3::Application::RegisterCompletedRun")
  end

  it "supports constructor-time direct file loading for migrated call sites" do
    stdout = assert_script(<<~'RUBY')
      require "a3/application/register_completed_run"
      require "a3/domain/merge_planning_policy"
      require "a3/domain/phase_source_policy"
      require "a3/infra/inherited_parent_state_resolver"
      require "a3/infra/agent_workspace_request_builder"
      require "a3/infra/local_workspace_provisioner"

      A3::Application::RegisterCompletedRun.new(
        task_repository: nil,
        run_repository: nil,
        plan_next_phase: nil,
        integration_ref_readiness_checker: Object.new
      )
      A3::Domain::MergePlanningPolicy.new
      A3::Domain::PhaseSourcePolicy.new
      A3::Infra::InheritedParentStateResolver.new(repo_sources: {})
      A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {})
      A3::Infra::LocalWorkspaceProvisioner.new(base_dir: Dir.pwd, git_workspace_backend: Object.new)

      puts "ok"
    RUBY
    expect(stdout).to include("ok")
  end
end
