# frozen_string_literal: true

require_relative "../../../scripts/a3-projects/portal/portal_runtime_surface"

RSpec.describe PortalRuntimeSurface do
  it "builds the shared CLI command prefix once" do
    expect(described_class.cli_command_prefix).to eq(["ruby", "-I", "a3-engine/lib", "a3-engine/bin/a3"])
  end

  it "exposes shared portal runtime paths" do
    expect(described_class::MANIFEST_PATH.to_s).to end_with("scripts/a3-projects/portal/config/portal/a3-runtime-manifest.yml")
    expect(described_class::SCHEDULER_LAUNCHER_SCRIPT.to_s).to end_with("scripts/a3-projects/portal/portal_scheduler_launcher.rb")
  end

  it "resolves the scheduler launcher path from an injected root dir" do
    expect(described_class.scheduler_launcher_script("/tmp/custom-root").to_s).to eq("/tmp/custom-root/scripts/a3-projects/portal/portal_scheduler_launcher.rb")
  end
end
