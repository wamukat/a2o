# frozen_string_literal: true

require "stringio"
require_relative "../../../scripts/a3/assert_a3_v2_live_write_enabled"

RSpec.describe A3LiveWriteGuard do
  it "passes when live write is explicitly enabled" do
    stdout = StringIO.new
    stderr = StringIO.new

    rc = described_class.main(env: { "A3_V2_ALLOW_LIVE_WRITE" => "1" }, stdout: stdout, stderr: stderr)

    expect(rc).to eq(0)
    expect(stdout.string).to include("A3-v2 live-write enabled")
    expect(stderr.string).to eq("")
  end

  it "fails fast when live write is not enabled" do
    stdout = StringIO.new
    stderr = StringIO.new

    rc = described_class.main(env: {}, stdout: stdout, stderr: stderr)

    expect(rc).to eq(1)
    expect(stdout.string).to eq("")
    expect(stderr.string).to include("Refusing A3-v2 live-write execution")
  end

  it "rejects non-canonical truthy values" do
    stdout = StringIO.new
    stderr = StringIO.new

    rc = described_class.main(env: { "A3_V2_ALLOW_LIVE_WRITE" => "true" }, stdout: stdout, stderr: stderr)

    expect(rc).to eq(1)
    expect(stdout.string).to eq("")
    expect(stderr.string).to include("Refusing A3-v2 live-write execution")
  end

  it "rejects whitespace-padded values" do
    stdout = StringIO.new
    stderr = StringIO.new

    rc = described_class.main(env: { "A3_V2_ALLOW_LIVE_WRITE" => " 1 " }, stdout: stdout, stderr: stderr)

    expect(rc).to eq(1)
    expect(stdout.string).to eq("")
    expect(stderr.string).to include("Refusing A3-v2 live-write execution")
  end
end
