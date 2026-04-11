# frozen_string_literal: true

require_relative "../../../scripts/a3/portal_v2_runtime_surface"

RSpec.describe PortalV2RuntimeSurface do
  it "builds the shared CLI command prefix once" do
    expect(described_class.cli_command_prefix).to eq(["ruby", "-I", "a3-engine/lib", "a3-engine/bin/a3"])
  end

  it "exposes shared portal runtime paths" do
    expect(described_class::MANIFEST_PATH.to_s).to end_with("scripts/a3/config/portal/a3-runtime-manifest.yml")
    expect(described_class::SCHEDULER_LAUNCHER_SCRIPT.to_s).to end_with("scripts/a3/portal_v2_scheduler_launcher.rb")
    expect(described_class::LAUNCHD_PLIST.to_s).to end_with(".work/a3/scheduler/portal/dev.a3.portal.scheduler.plist")
  end

  it "resolves the scheduler launcher path from an injected root dir" do
    expect(described_class.scheduler_launcher_script("/tmp/custom-root").to_s).to eq("/tmp/custom-root/scripts/a3/portal_v2_scheduler_launcher.rb")
  end
end
