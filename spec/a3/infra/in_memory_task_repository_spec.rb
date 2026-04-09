# frozen_string_literal: true

RSpec.describe A3::Infra::InMemoryTaskRepository do
  it "implements the task repository port" do
    expect(described_class.ancestors).to include(A3::Domain::TaskRepository)
  end

  it "stores and fetches immutable task instances by ref" do
    repository = described_class.new
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )

    repository.save(task)

    expect(repository.fetch(task.ref)).to eq(task)
  end

  it "raises RecordNotFound for unknown refs" do
    repository = described_class.new

    expect { repository.fetch("A3-v2#9999") }.to raise_error(A3::Domain::RecordNotFound)
  end

  it "deletes tasks by ref" do
    repository = described_class.new
    task = A3::Domain::Task.new(ref: "A3-v2#3025", kind: :child, edit_scope: [:repo_alpha])
    repository.save(task)

    repository.delete(task.ref)

    expect { repository.fetch(task.ref) }.to raise_error(A3::Domain::RecordNotFound)
  end
end
