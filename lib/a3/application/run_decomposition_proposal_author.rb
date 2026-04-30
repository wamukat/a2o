# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "decomposition_workspace_permissions"

module A3
  module Application
    class RunDecompositionProposalAuthor
      include DecompositionWorkspacePermissions

      Result = Struct.new(:success, :summary, :source_ticket_summary, :source_ticket_summary_published, :proposal, :proposal_fingerprint, :request_path, :result_path, :workspace_root, :evidence_path, :failing_command, :observed_state, keyword_init: true)

      def initialize(storage_dir:, project_root: Dir.pwd, process_runner: nil, publish_external_task_activity: nil, clock: -> { Time.now.utc }, host_shared_root: nil, container_shared_root: nil, command_workspace_dir: nil)
        @storage_dir = storage_dir
        @command_workspace_dir = command_workspace_dir
        @project_root = project_root
        @process_runner = process_runner || method(:run_process)
        @publish_external_task_activity = publish_external_task_activity
        @clock = clock
        @host_shared_root = clean_root(host_shared_root)
        @container_shared_root = clean_root(container_shared_root)
      end

      def call(task:, project_surface:, investigation_evidence: nil, investigation_evidence_path: nil)
        command = project_surface.decomposition_author_command
        raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.author.command must be provided" unless command

        workspace_root = prepare_workspace_root(task_ref: task.ref)
        request_path = File.join(workspace_root, ".a2o", "decomposition-proposal-request.json")
        result_path = File.join(workspace_root, ".a2o", "decomposition-proposal-result.json")
        FileUtils.mkdir_p(File.dirname(request_path))
        make_shared_workspace_tree(File.dirname(request_path))
        FileUtils.rm_f(result_path)

        investigation_evidence = load_investigation_evidence(investigation_evidence, investigation_evidence_path)
        request = request_payload(
          task: task,
          project_surface: project_surface,
          investigation_evidence: investigation_evidence,
          investigation_evidence_path: command_path(investigation_evidence_path),
          workspace_root: command_path(workspace_root)
        )
        write_json(request_path, request)

        command = resolve_command(command)
        stdout, stderr, status = run_command(command: command, workspace_root: workspace_root, request_path: request_path, result_path: result_path)

        raw_proposal = load_result(result_path)
        proposal = normalize_proposal(task: task, proposal: raw_proposal, investigation_evidence: investigation_evidence)
        errors = proposal_validation_errors(proposal)
        success = status.success? && errors.empty?
        summary = summary_for(success: success, command: command, status: status, proposal: proposal, raw_proposal: raw_proposal, errors: errors, stderr: stderr)
        source_ticket_summary = source_ticket_summary_for(success: success, summary: summary, proposal: proposal, validation_errors: errors)
        evidence_path = persist_evidence(
          task: task,
          command: command,
          request: request,
          result: raw_proposal,
          proposal: proposal,
          success: success,
          summary: summary,
          source_ticket_summary: source_ticket_summary,
          stdout: stdout,
          stderr: stderr,
          status: status,
          workspace_root: workspace_root,
          request_path: request_path,
          result_path: result_path,
          validation_errors: errors
        )
        summary_published = publish_source_ticket_summary(task: task, body: source_ticket_summary)

        Result.new(
          success: success,
          summary: summary,
          source_ticket_summary: source_ticket_summary,
          source_ticket_summary_published: summary_published,
          proposal: success ? proposal : nil,
          proposal_fingerprint: success ? proposal.fetch("proposal_fingerprint") : nil,
          request_path: request_path,
          result_path: result_path,
          workspace_root: workspace_root,
          evidence_path: evidence_path,
          failing_command: success ? nil : command.join(" "),
          observed_state: success ? nil : observed_state(status: status, proposal: raw_proposal, errors: errors, stderr: stderr)
        )
      end

      private

      CommandStatus = Struct.new(:success?, :exitstatus)

      def run_command(command:, workspace_root:, request_path:, result_path:)
        @process_runner.call(
          command,
          chdir: command_path(workspace_root),
          env: {
            "A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH" => command_path(request_path),
            "A2O_DECOMPOSITION_AUTHOR_RESULT_PATH" => command_path(result_path),
            "A2O_WORKSPACE_ROOT" => command_path(workspace_root),
            "A2O_ROOT_DIR" => command_path(@project_root)
          }
        )
      rescue SystemCallError => e
        ["", e.message, CommandStatus.new(false, nil)]
      end

      def prepare_workspace_root(task_ref:)
        base_dir = File.join(@command_workspace_dir || File.join(@storage_dir, "decomposition-workspaces"), slugify(task_ref))
        make_shared_workspace_dir(base_dir)
        Dir.mktmpdir("proposal-#{@clock.call.strftime('%Y%m%d%H%M%S')}-", base_dir).tap do |path|
          make_shared_workspace_tree(path)
        end
      end

      def request_payload(task:, project_surface:, investigation_evidence:, investigation_evidence_path:, workspace_root:)
        payload = {
          "task_ref" => task.ref,
          "task_kind" => task.kind.to_s,
          "labels" => task.labels,
          "priority" => task.priority,
          "parent_ref" => task.parent_ref,
          "child_refs" => task.child_refs,
          "blocking_task_refs" => task.blocking_task_refs,
          "investigation_evidence_path" => investigation_evidence_path,
          "investigation_evidence" => investigation_evidence,
          "workspace_root" => workspace_root
        }
        project_prompt = decomposition_project_prompt(project_surface.prompt_config, task)
        payload["project_prompt"] = project_prompt if project_prompt
        payload
      end

      def decomposition_project_prompt(prompt_config, task)
        return nil unless prompt_config && !prompt_config.empty?

        phase_config = prompt_config.phase(:decomposition)
        repo_slots = decomposition_prompt_repo_slots(task)
        layers = []
        if prompt_config.system_document
          layers << prompt_layer("project_system_prompt", prompt_config.system_document.path, prompt_config.system_document.content)
        end
        phase_config.prompt_documents.each do |document|
          layers << prompt_layer("project_phase_prompt", document.path, document.content)
        end
        phase_config.skill_documents.each do |document|
          layers << prompt_layer("project_phase_skill", document.path, document.content)
        end
        if phase_config.child_draft_template_document
          layers << prompt_layer("decomposition_child_draft_template", phase_config.child_draft_template_document.path, phase_config.child_draft_template_document.content)
        end
        repo_slots.each do |repo_slot|
          repo_slot_config = prompt_config.repo_slot_addon_phase(repo_slot, :decomposition)
          next if repo_slot_config.empty?

          repo_slot_config.prompt_documents.each do |document|
            layers << prompt_layer("repo_slot_phase_prompt", "#{repo_slot}:#{document.path}", document.content)
          end
          repo_slot_config.skill_documents.each do |document|
            layers << prompt_layer("repo_slot_phase_skill", "#{repo_slot}:#{document.path}", document.content)
          end
          if repo_slot_config.child_draft_template_document
            layers << prompt_layer("repo_slot_decomposition_child_draft_template", "#{repo_slot}:#{repo_slot_config.child_draft_template_document.path}", repo_slot_config.child_draft_template_document.content)
          end
        end
        return nil if layers.empty?

        {
          "profile" => "decomposition",
          "repo_slot" => (repo_slots.one? ? repo_slots.first : nil),
          "repo_slots" => repo_slots,
          "layers" => layers,
          "composed_instruction" => layers.map { |layer| "## #{layer.fetch("title")}\n#{layer.fetch("content")}" }.join("\n\n")
        }
      end

      def decomposition_prompt_repo_slots(task)
        task_slots = task.respond_to?(:repo_slots) ? Array(task.repo_slots).map(&:to_s).reject(&:empty?) : []
        return task_slots unless task_slots.empty?
        return [] if task.edit_scope.empty?

        repo_scope = task.repo_scope_key.to_s
        return [] if repo_scope.empty?
        return [repo_scope] unless repo_scope == "both"

        task.edit_scope.map(&:to_s).reject(&:empty?).uniq
      end

      def prompt_layer(kind, title, content)
        {
          "kind" => kind,
          "title" => title,
          "content" => content
        }
      end

      def evidence_request_payload(request)
        payload = stringify_keys(request)
        project_prompt = payload["project_prompt"]
        payload["project_prompt"] = project_prompt_metadata(project_prompt) if project_prompt.is_a?(Hash)
        payload
      end

      def project_prompt_metadata(project_prompt)
        layers = Array(project_prompt["layers"]).map do |layer|
          next unless layer.is_a?(Hash)

          content = layer.fetch("content", "").to_s
          {
            "kind" => layer["kind"].to_s,
            "title" => layer["title"].to_s,
            "content_sha256" => Digest::SHA256.hexdigest(content),
            "content_bytes" => content.bytesize
          }
        end.compact
        composed = project_prompt.fetch("composed_instruction", "").to_s
        {
          "profile" => project_prompt["profile"].to_s,
          "repo_slot" => project_prompt["repo_slot"].to_s,
          "repo_slots" => Array(project_prompt["repo_slots"]).map(&:to_s).reject(&:empty?),
          "layers" => layers,
          "composed_instruction_sha256" => Digest::SHA256.hexdigest(composed),
          "composed_instruction_bytes" => composed.bytesize
        }
      end

      def load_investigation_evidence(value, path)
        return value if value
        return nil unless path

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def load_result(result_path)
        return nil unless File.exist?(result_path)

        payload = JSON.parse(File.read(result_path))
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError
        nil
      end

      def normalize_proposal(task:, proposal:, investigation_evidence:)
        return nil unless proposal.is_a?(Hash)

        normalized = stringify_keys(proposal)
        normalized["source_ticket_ref"] = task.ref
        normalized["outcome"] = normalized_outcome(normalized["outcome"])
        normalized["reason"] = normalized["reason"].to_s.strip if normalized.key?("reason")
        normalized["questions"] = normalized["questions"].map(&:to_s) if normalized["questions"].is_a?(Array)
        normalized["evidence"] = normalized["evidence"].map(&:to_s) if normalized["evidence"].is_a?(Array)
        normalized["parent"] = normalize_parent(normalized["parent"]) if normalized.key?("parent")
        normalized["unresolved_questions"] = [] if !normalized.key?("unresolved_questions") && normalized["outcome"] != "draft_children"
        if normalized["children"].is_a?(Array)
          normalized["children"] = normalized["children"].map do |child|
            normalize_child(task_ref: task.ref, child: stringify_keys(child))
          end
        end
        if normalized["unresolved_questions"].is_a?(Array)
          normalized["unresolved_questions"] = normalized["unresolved_questions"].map(&:to_s)
        end
        normalized["proposal_fingerprint"] = proposal_fingerprint_for(
          task_ref: task.ref,
          investigation_evidence: investigation_evidence,
          proposal: normalized.reject { |key, _| key == "proposal_fingerprint" }
        )
        normalized
      end

      def normalize_child(task_ref:, child:)
        %w[acceptance_criteria labels depends_on].each do |key|
          child[key] = child[key].map(&:to_s) if child[key].is_a?(Array)
        end
        child["child_key"] = child_key_for(task_ref: task_ref, child: child)
        child
      end

      def proposal_validation_errors(proposal)
        return ["proposal result JSON is missing or invalid"] unless proposal.is_a?(Hash)

        errors = []
        errors << "source_ticket_ref must be a non-empty string" unless non_empty_string?(proposal["source_ticket_ref"])
        errors << "proposal_fingerprint must be a non-empty string" unless non_empty_string?(proposal["proposal_fingerprint"])
        errors << "outcome must be one of draft_children, no_action, needs_clarification" unless valid_outcome?(proposal["outcome"])
        children = proposal["children"]
        errors << "children must be an array" unless children.is_a?(Array)
        if proposal["outcome"] == "draft_children"
          errors << "children must be a non-empty array" unless children.is_a?(Array) && children.any?
        elsif children.is_a?(Array) && children.any?
          errors << "children must be empty for #{proposal['outcome']} outcome"
        end
        child_keys = []
        Array(children).each_with_index do |child, index|
          errors.concat(child_validation_errors(child, index))
          child_keys << child["child_key"] if child.is_a?(Hash)
        end
        errors << "children child_key values must be unique" if child_keys.size != child_keys.uniq.size
        errors << "unresolved_questions must be an array" unless proposal["unresolved_questions"].is_a?(Array)
        errors << "reason must be a non-empty string for #{proposal['outcome']} outcome" if %w[no_action needs_clarification].include?(proposal["outcome"]) && !non_empty_string?(proposal["reason"])
        if proposal["outcome"] == "needs_clarification"
          errors << "questions must be a non-empty array for needs_clarification outcome" unless proposal["questions"].is_a?(Array) && proposal["questions"].any? { |question| non_empty_string?(question) }
        end
        errors << "evidence must be an array when provided" if proposal.key?("evidence") && !proposal["evidence"].is_a?(Array)
        errors.concat(parent_validation_errors(proposal["parent"], outcome: proposal["outcome"])) if proposal.key?("parent")
        errors
      end

      def child_validation_errors(child, index)
        prefix = "children[#{index}]"
        return ["#{prefix} must be an object"] unless child.is_a?(Hash)

        errors = []
        %w[child_key title body rationale boundary].each do |key|
          errors << "#{prefix}.#{key} must be a non-empty string" unless non_empty_string?(child[key])
        end
        %w[acceptance_criteria labels depends_on].each do |key|
          errors << "#{prefix}.#{key} must be an array" unless child[key].is_a?(Array)
        end
        errors
      end

      def summary_for(success:, command:, status:, proposal:, raw_proposal:, errors:, stderr:)
        return success_summary_for(proposal) if success
        return "#{command.join(' ')} failed to launch: #{stderr}" if status.exitstatus.nil?
        return "#{command.join(' ')} failed with exit #{status.exitstatus}" unless status.success?
        return "proposal result JSON is missing or invalid" unless raw_proposal

        errors.join("; ")
      end

      def source_ticket_summary_for(success:, summary:, proposal:, validation_errors:)
        lines = ["Decomposition proposal: #{summary}"]
        if success
          lines << "Proposal fingerprint: #{proposal.fetch('proposal_fingerprint')}"
          lines << "Outcome: #{proposal.fetch('outcome')}"
          lines << "Child drafts: #{proposal.fetch('children', []).size}"
          lines << "Reason: #{proposal.fetch('reason')}" if non_empty_string?(proposal["reason"])
          lines << "Questions: #{proposal.fetch('questions', []).size}" if proposal["outcome"] == "needs_clarification"
          questions = proposal.fetch("unresolved_questions")
          lines << "Unresolved questions: #{questions.empty? ? 'none' : questions.size}"
        else
          lines << "Status: blocked"
          lines << "Validation: #{validation_errors.join('; ')}" unless validation_errors.empty?
        end
        lines.join("\n")
      end

      def publish_source_ticket_summary(task:, body:)
        return false unless @publish_external_task_activity
        return false unless task.external_task_id

        @publish_external_task_activity.publish(
          task_ref: task.ref,
          external_task_id: task.external_task_id,
          body: body
        )
        true
      end

      def persist_evidence(task:, command:, request:, result:, proposal:, success:, summary:, source_ticket_summary:, stdout:, stderr:, status:, workspace_root:, request_path:, result_path:, validation_errors:)
        evidence_dir = File.join(@storage_dir, "decomposition-evidence", slugify(task.ref))
        FileUtils.mkdir_p(evidence_dir)
        evidence_path = File.join(evidence_dir, "proposal.json")
        write_json(
          evidence_path,
          {
            "task_ref" => task.ref,
            "phase" => "proposal",
            "success" => success,
            "summary" => summary,
            "source_ticket_summary" => source_ticket_summary,
            "proposal_fingerprint" => proposal&.fetch("proposal_fingerprint", nil),
            "command" => command,
            "exit_status" => status.exitstatus,
            "request_path" => request_path,
            "result_path" => result_path,
            "workspace_root" => workspace_root,
            "request" => evidence_request_payload(request),
            "result" => result,
            "proposal" => proposal,
            "validation_errors" => validation_errors,
            "stdout" => stdout,
            "stderr" => stderr
          }
        )
        evidence_path
      end

      def observed_state(status:, proposal:, errors:, stderr:)
        return "launch_error: #{stderr}" if status.exitstatus.nil?
        return "exit #{status.exitstatus}" unless status.success?
        return "missing_or_invalid_proposal_json" unless proposal

        errors.join("; ")
      end

      def proposal_fingerprint_for(task_ref:, investigation_evidence:, proposal:)
        digest_payload = {
          "source_ticket_ref" => task_ref,
          "investigation_result_digest" => Digest::SHA256.hexdigest(canonical_json(investigation_evidence || {})),
          "proposal" => proposal
        }
        Digest::SHA256.hexdigest(canonical_json(digest_payload))
      end

      def child_key_for(task_ref:, child:)
        Digest::SHA256.hexdigest(canonical_json("source_ticket_ref" => task_ref, "boundary" => child["boundary"].to_s))[0, 24]
      end

      def normalized_outcome(value)
        outcome = value.to_s.strip
        outcome.empty? ? "draft_children" : outcome
      end

      def valid_outcome?(value)
        %w[draft_children no_action needs_clarification].include?(value)
      end

      def normalize_parent(parent)
        return parent unless parent.is_a?(Hash)

        stringify_keys(parent).each_with_object({}) do |(key, value), memo|
          memo[key] = value.is_a?(String) ? value.strip : value
        end
      end

      def parent_validation_errors(parent, outcome:)
        prefix = "parent"
        return ["#{prefix} must be an object"] unless parent.is_a?(Hash)
        return ["#{prefix} is only supported for draft_children outcome"] unless outcome == "draft_children"

        errors = []
        %w[title body].each do |key|
          next unless parent.key?(key)

          errors << "#{prefix}.#{key} must be a non-empty string when provided" unless non_empty_string?(parent[key])
        end
        errors
      end

      def success_summary_for(proposal)
        fingerprint = proposal.fetch("proposal_fingerprint")
        outcome = proposal.fetch("outcome")
        case outcome
        when "draft_children"
          "proposal #{fingerprint} with #{proposal.fetch('children').size} child drafts"
        when "no_action"
          "proposal #{fingerprint} outcome=no_action"
        when "needs_clarification"
          "proposal #{fingerprint} outcome=needs_clarification with #{proposal.fetch('questions', []).size} question(s)"
        else
          "proposal #{fingerprint} outcome=#{outcome}"
        end
      end

      def canonical_json(value)
        JSON.generate(canonicalize(value))
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, memo|
            item = value.key?(key) ? value[key] : value[key.to_sym]
            memo[key] = canonicalize(item)
          end
        when Array
          value.map { |item| canonicalize(item) }
        else
          value
        end
      end

      def stringify_keys(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = item }
      end

      def non_empty_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def resolve_command(command)
        first, *rest = command
        resolved_first =
          if relative_path_command?(first)
            command_path(File.expand_path(first, @project_root))
          else
            first
          end
        [resolved_first, *rest]
      end

      def relative_path_command?(value)
        value.include?(File::SEPARATOR) && Pathname.new(value).relative?
      end

      def write_json(path, payload)
        File.write(path, "#{JSON.pretty_generate(payload)}\n")
      end

      def command_path(path)
        value = path.to_s
        return value if value.empty? || !@host_shared_root || !@container_shared_root
        return @host_shared_root if value == @container_shared_root
        return File.join(@host_shared_root, value.delete_prefix("#{@container_shared_root}/")) if value.start_with?("#{@container_shared_root}/")

        value
      end

      def clean_root(path)
        value = path.to_s.sub(%r{/+\z}, "")
        value.empty? ? nil : value
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def run_process(command, chdir:, env:)
        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        [stdout, stderr, status]
      end
    end
  end
end
