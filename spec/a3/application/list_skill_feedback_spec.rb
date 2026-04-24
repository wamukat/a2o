# frozen_string_literal: true

RSpec.describe A3::Application::ListSkillFeedback do
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }

  it "lists persisted skill feedback across run phase records" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A2O#187",
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A2O#187", ref: "refs/heads/a2o/work/A2O-187"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:app],
        verification_scope: [:app],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A2O#187",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/A2O-187"
      )
    ).append_phase_evidence(
      phase: :implementation,
      source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A2O#187", ref: "refs/heads/a2o/work/A2O-187"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:app],
        verification_scope: [:app],
        ownership_scope: :task
      ),
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "implemented",
        skill_feedback: [
          {
            "category" => "missing_context",
            "summary" => "Add recurring verification setup guidance.",
            "repo_scope" => "app",
            "skill_path" => "skills/implementation/base.md",
            "proposal" => { "target" => "project_skill" },
            "confidence" => "medium",
            "state" => "accepted",
            "evidence" => { "verification_commands" => ["bundle exec rspec"] }
          }
        ]
      )
    )
    run_repository.save(run)

    entries = described_class.new(run_repository: run_repository).call

    expect(entries).to contain_exactly(
      have_attributes(
        task_ref: "A2O#187",
        run_ref: "run-1",
        phase: :implementation,
        category: "missing_context",
        summary: "Add recurring verification setup guidance.",
        target: "project_skill",
        repo_scope: "app",
        skill_path: "skills/implementation/base.md",
        confidence: "medium",
        state: "accepted",
        evidence: { "verification_commands" => ["bundle exec rspec"] },
        group_key: A3::Domain::SkillFeedback.group_key_for(
          "category" => "missing_context",
          "summary" => "Add recurring verification setup guidance.",
          "skill_path" => "skills/implementation/base.md",
          "proposal" => { "target" => "project_skill" }
        )
      )
    )
  end

  it "filters and groups persisted skill feedback" do
    2.times do |index|
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-#{index}",
          task_ref: "A2O#20#{index}",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A2O#20#{index}", ref: "refs/heads/a2o/work/A2O-20#{index}"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:app], verification_scope: [:app], ownership_scope: :task),
          artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "A2O#20#{index}", owner_scope: :task, snapshot_version: "refs/heads/a2o/work/A2O-20#{index}")
        ).append_phase_evidence(
          phase: :implementation,
          source_descriptor: A3::Domain::SourceDescriptor.ticket_branch_head(task_ref: "A2O#20#{index}", ref: "refs/heads/a2o/work/A2O-20#{index}"),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:app], verification_scope: [:app], ownership_scope: :task),
          execution_record: A3::Domain::PhaseExecutionRecord.new(
            summary: "implemented",
            skill_feedback: [
              {
                "category" => "missing_context",
                "summary" => "Add recurring verification setup guidance.",
                "skill_path" => "skills/implementation/base.md",
                "proposal" => { "target" => "project_skill" }
              }
            ]
          )
        )
      )
    end

    groups = described_class.new(run_repository: run_repository).call(state: "new", group: true)

    expect(groups.size).to eq(1)
    expect(groups.first.count).to eq(2)
    expect(groups.first.representative.summary).to eq("Add recurring verification setup guidance.")
  end
end
