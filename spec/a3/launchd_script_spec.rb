# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3/launchd"

RSpec.describe A3Launchd do
  before do
    @temp_dir = Dir.mktmpdir("a3-launchd-")
    @plist_path = File.join(@temp_dir, "portal.plist")
    File.write(
      @plist_path,
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>dev.a3.portal.watch</string>
          </dict>
        </plist>
      XML
    )
  end

  after do
    FileUtils.remove_entry(@temp_dir)
  end

  it "bootstraps the plist on install" do
    allow(described_class).to receive(:find_launchctl).and_return("/bin/launchctl")
    allow(described_class).to receive(:gui_domain_target).and_return("gui/501")
    allow(described_class).to receive(:run).and_return(0)

    rc = described_class.main(["install", "--plist", @plist_path])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run).with("launchctl", "bootstrap", "gui/501", File.expand_path(@plist_path))
  end

  it "boots out, bootstraps, and kickstarts on reload" do
    allow(described_class).to receive(:find_launchctl).and_return("/bin/launchctl")
    allow(described_class).to receive(:gui_domain_target).and_return("gui/501")
    allow(described_class).to receive(:run).and_return(0)

    rc = described_class.main(["reload", "--plist", @plist_path])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run).with("launchctl", "bootout", "gui/501", File.expand_path(@plist_path), check: false)
    expect(described_class).to have_received(:run).with("launchctl", "bootstrap", "gui/501", File.expand_path(@plist_path))
    expect(described_class).to have_received(:run).with("launchctl", "kickstart", "-k", "gui/501/dev.a3.portal.watch")
  end

  it "prints status for the label" do
    allow(described_class).to receive(:find_launchctl).and_return("/bin/launchctl")
    allow(described_class).to receive(:gui_domain_target).and_return("gui/501")
    allow(described_class).to receive(:run).and_return(0)

    rc = described_class.main(["status", "--plist", @plist_path])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run).with("launchctl", "print", "gui/501/dev.a3.portal.watch")
  end

  it "fails fast outside macOS" do
    expect do
      described_class.ensure_launchd_supported(platform: "linux", launchctl_path: nil)
    end.to raise_error(SystemExit, "A3 launchd helper is supported on macOS only.")
  end
end
