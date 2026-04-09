# frozen_string_literal: true

RSpec.describe A3::Domain::ArtifactOwner do
  it "serializes and restores the persisted contract" do
    owner = described_class.new(
      owner_ref: "A3-v2#3022",
      owner_scope: :task,
      snapshot_version: "refs/heads/a3/work/3022"
    )

    expect(owner.persisted_form).to eq(
      "owner_ref" => "A3-v2#3022",
      "owner_scope" => "task",
      "snapshot_version" => "refs/heads/a3/work/3022"
    )
    expect(described_class.from_persisted_form(owner.persisted_form)).to eq(owner)
  end

  it "rejects a missing snapshot_version" do
    expect do
      described_class.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: nil
      )
    end.to raise_error(A3::Domain::ConfigurationError, /snapshot_version must be provided/)
  end
end
