# frozen_string_literal: true

RSpec.describe "Kanban-first decomposition draft flow" do
  class FakeKanbanFirstDraftClient
    attr_reader :created, :commands, :comments

    def initialize
      @tasks = {
        "Portal#240" => { "id" => 240, "ref" => "Portal#240", "title" => "Remote parent", "description" => "Parent" }
      }
      @tasks_by_id = { 240 => @tasks.fetch("Portal#240") }
      @labels = { 240 => ["trigger:investigate", "repo:portal"] }
      @relations = Hash.new { |hash, key| hash[key] = { "subtask" => [], "blocked" => [], "related" => [] } }
      @created = []
      @commands = []
      @comments = []
    end

    def run_json_command(*args)
      case args.first
      when "task-find"
        query = args.fetch(args.index("--query") + 1)
        @tasks.values.select do |task|
          task.fetch("description", "").include?("Child key: #{query}") ||
            task.fetch("description", "").include?("Decomposition source: #{query}")
        end
      when "task-create"
        create_task(args)
      when "task-relation-list"
        @relations[Integer(args.fetch(args.index("--task-id") + 1))]
      else
        {}
      end
    end

    def run_json_command_with_text_file_option(*args, text:, **)
      run_json_command(*args).tap { |task| task["description"] = text if task.is_a?(Hash) }
    end

    def run_command(*args)
      @commands << args
      case args.first
      when "task-label-add"
        label = args.fetch(args.index("--label") + 1)
        labels_for(args.fetch(args.index("--task-id") + 1)) << label unless labels_for(args.fetch(args.index("--task-id") + 1)).include?(label)
      when "task-label-remove"
        labels_for(args.fetch(args.index("--task-id") + 1)).delete(args.fetch(args.index("--label") + 1))
      when "task-relation-create"
        create_relation(args)
      end
      nil
    end

    def run_command_with_text_file_option(*args, text:, **)
      @comments << [args, text]
      run_command(*args)
    end

    def fetch_task_by_id(task_id)
      @tasks_by_id.fetch(Integer(task_id))
    end

    def fetch_task_by_ref(ref)
      @tasks.fetch(ref)
    end

    def load_task_labels(task_id)
      labels_for(task_id)
    end

    def labels_for(task_id)
      @labels[Integer(task_id)] ||= []
    end

    private

    def create_task(args)
      id = 241 + @created.size
      ref = "Portal##{id}"
      task = {
        "id" => id,
        "ref" => ref,
        "title" => args.fetch(args.index("--title") + 1),
        "status" => args.fetch(args.index("--status") + 1),
        "description" => ""
      }
      @tasks[ref] = task
      @tasks_by_id[id] = task
      @labels[id] = []
      @created << task
      task
    end

    def create_relation(args)
      task_id = Integer(args.fetch(args.index("--task-id") + 1))
      other_id = Integer(args.fetch(args.index("--other-task-id") + 1))
      kind = args.fetch(args.index("--relation-kind") + 1)
      if kind == "subtask"
        @relations[task_id]["subtask"] << { "id" => other_id, "ref" => @tasks_by_id.fetch(other_id).fetch("ref") }
      elsif kind == "blocked"
        @relations[task_id]["blocked"] << { "id" => other_id, "ref" => @tasks_by_id.fetch(other_id).fetch("ref") }
      elsif kind == "related"
        @relations[task_id]["related"] << { "id" => other_id, "ref" => @tasks_by_id.fetch(other_id).fetch("ref") }
      end
    end
  end

  def proposal_evidence
    {
      "proposal_fingerprint" => "fp-remote-1",
      "proposal" => {
        "children" => [
          {
            "child_key" => "portal-routing",
            "title" => "Add portal routing",
            "body" => "Implement routing.",
            "acceptance_criteria" => ["routes work"],
            "labels" => ["repo:portal", "trigger:auto-implement", "trigger:auto-parent"],
            "depends_on" => [],
            "rationale" => "small independent slice"
          }
        ]
      }
    }
  end

  it "creates draft children, preserves rerun edits, and accepts them before parent automation" do
    Dir.mktmpdir do |dir|
      client = FakeKanbanFirstDraftClient.new
      source_task = A3::Domain::Task.new(
        ref: "wamukat/a2o#16",
        kind: :single,
        edit_scope: [:repo_beta],
        external_task_id: 240,
        labels: ["trigger:investigate", "repo:portal"]
      )
      proposal_path = File.join(dir, "proposal.json")
      review_path = File.join(dir, "proposal-review.json")
      File.write(proposal_path, JSON.generate(proposal_evidence.merge("success" => true)))
      File.write(
        review_path,
        JSON.generate(
          "disposition" => "eligible",
          "request" => {
            "proposal_evidence" => {
              "proposal_fingerprint" => "fp-remote-1"
            }
          }
        )
      )
      draft_writer = A3::Infra::KanbanCliProposalChildWriter.new(project: "Portal", client: client, mode: :draft)
      child_creation = A3::Application::RunDecompositionChildCreation.new(storage_dir: dir, child_writer: draft_writer)

      first = child_creation.call(task: source_task, gate: true, proposal_evidence_path: proposal_path, review_evidence_path: review_path)

      expect(first.success).to be(true)
      expect(first.parent_ref).to eq("Portal#241")
      expect(first.child_refs).to eq(["Portal#242"])
      expect(client.created.size).to eq(2)
      expect(client.fetch_task_by_ref("Portal#241").fetch("status")).to eq("Backlog")
      expect(client.fetch_task_by_ref("Portal#242").fetch("status")).to eq("Backlog")
      expect(client.labels_for(241)).to include("a2o:decomposed")
      expect(client.labels_for(242)).to include("a2o:draft-child", "repo:portal")
      expect(client.labels_for(242)).not_to include("trigger:auto-implement", "trigger:auto-parent")
      expect(client.labels_for(240)).not_to include("trigger:auto-parent")

      task_repository = A3::Infra::InMemoryTaskRepository.new
      task_repository.save(source_task)
      task_repository.save(A3::Domain::Task.new(ref: "Portal#242", kind: :child, edit_scope: [:repo_beta], parent_ref: "Portal#241", labels: client.labels_for(242)))
      plan = A3::Application::PlanNextRunnableTask.new(task_repository: task_repository, sync_external_tasks: nil).call
      draft_assessment = plan.assessments.find { |assessment| assessment.task_ref == "Portal#242" }
      expect(draft_assessment.reason).to eq(:draft_child_not_accepted)

      client.fetch_task_by_ref("Portal#242")["title"] = "Human edited title"
      second = child_creation.call(task: source_task, gate: true, proposal_evidence_path: proposal_path, review_evidence_path: review_path)
      expect(second.success).to be(true)
      expect(client.created.size).to eq(2)
      expect(client.fetch_task_by_ref("Portal#242").fetch("title")).to eq("Human edited title")

      accept_writer = A3::Infra::KanbanCliDraftAcceptanceWriter.new(project: "Portal", client: client)
      accepted = accept_writer.call(parent_task_ref: source_task.ref, parent_external_task_id: 240, child_refs: ["Portal#242"], parent_auto: true)

      expect(accepted.success?).to be(true)
      expect(accepted.accepted_refs).to eq(["Portal#242"])
      expect(client.labels_for(242)).to include("trigger:auto-implement")
      expect(client.labels_for(241)).to include("trigger:auto-parent", "repo:portal")
      expect(client.labels_for(240)).not_to include("trigger:auto-parent")
      expect(client.fetch_task_by_ref("Portal#242").fetch("status")).to eq("Backlog")

      task_repository.save(A3::Domain::Task.new(ref: "Portal#242", kind: :child, edit_scope: [:repo_beta], status: :backlog, parent_ref: "Portal#241", labels: client.labels_for(242)))
      accepted_plan = A3::Application::PlanNextRunnableTask.new(task_repository: task_repository, sync_external_tasks: nil).call
      expect(accepted_plan.task).to be_nil
      task_repository.save(A3::Domain::Task.new(ref: "Portal#242", kind: :child, edit_scope: [:repo_beta], status: :todo, parent_ref: "Portal#241", labels: client.labels_for(242)))
      runnable_plan = A3::Application::PlanNextRunnableTask.new(task_repository: task_repository, sync_external_tasks: nil).call
      expect(runnable_plan.task&.ref).to eq("Portal#242")
      parent_after_acceptance = A3::Domain::Task.new(ref: "Portal#241", kind: :parent, edit_scope: [:repo_beta], child_refs: ["Portal#242"], labels: client.labels_for(241))
      parent_assessment = A3::Domain::RunnableTaskAssessment.evaluate(task: parent_after_acceptance, tasks: [parent_after_acceptance])
      expect(parent_assessment.reason).not_to eq(:decomposition_requested)

      comment_count = client.comments.size
      rerun_accept = accept_writer.call(parent_task_ref: source_task.ref, parent_external_task_id: 240, child_refs: ["Portal#242"], parent_auto: true)
      expect(rerun_accept.success?).to be(true)
      expect(client.comments.size).to eq(comment_count)
    end
  end
end
