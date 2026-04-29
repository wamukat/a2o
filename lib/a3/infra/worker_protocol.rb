# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "open3"
require "a3/domain/skill_feedback"

module A3
  module Infra
    class WorkerProtocol
      def initialize(repo_scope_aliases: {}, review_disposition_repo_scopes: nil)
        @repo_scope_aliases = normalize_repo_scope_aliases(repo_scope_aliases)
        @review_disposition_repo_scopes = normalize_configured_review_disposition_repo_scopes(review_disposition_repo_scopes)
      end

      def metadata_dir(workspace)
        workspace.root_path.join(".a2o")
      end

      def result_path(workspace)
        workspace.root_path.join(".a2o", "worker-result.json")
      end

      def env_for(workspace)
        workspace_root = workspace.root_path.to_s
        {
          "A2O_WORKER_REQUEST_PATH" => metadata_dir(workspace).join("worker-request.json").to_s,
          "A2O_WORKER_RESULT_PATH" => result_path(workspace).to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root
        }.merge(workspace_automation_env(workspace_root))
      end

      def request_form(skill:, workspace:, task:, run:, phase_runtime:, task_packet:, command_intent: nil, prior_review_feedback: nil)
        review_target = run.evidence.review_target
        phase_runtime_form = phase_runtime.worker_request_form
        phase_runtime_form = phase_runtime_form.merge("prior_review_feedback" => prior_review_feedback) if prior_review_feedback
        project_prompt = project_prompt_form(
          skill: skill,
          phase_runtime: phase_runtime,
          task_packet: task_packet,
          prior_review_feedback: prior_review_feedback
        )
        phase_runtime_form = phase_runtime_form.merge("project_prompt" => project_prompt) if project_prompt
        project_key = run.project_key || task.project_key
        payload = {
          "task_ref" => task.ref,
          "run_ref" => run.ref,
          "phase" => run.phase.to_s,
          "skill" => skill,
          "workspace_kind" => workspace.workspace_kind.to_s,
          "source_descriptor" => {
            "workspace_kind" => run.source_descriptor.workspace_kind.to_s,
            "source_type" => run.source_descriptor.source_type.to_s,
            "ref" => run.source_descriptor.ref,
            "task_ref" => run.source_descriptor.task_ref
          },
          "scope_snapshot" => {
            "edit_scope" => run.scope_snapshot.edit_scope.map(&:to_s),
            "verification_scope" => run.scope_snapshot.verification_scope.map(&:to_s),
            "ownership_scope" => run.scope_snapshot.ownership_scope.to_s
          },
          "artifact_owner" => {
            "owner_ref" => run.artifact_owner.owner_ref,
            "owner_scope" => run.artifact_owner.owner_scope.to_s,
            "snapshot_version" => run.artifact_owner.snapshot_version
          },
          "task_packet" => task_packet.request_form,
          "review_target" => review_target && {
            "base_commit" => review_target.base_commit,
            "head_commit" => review_target.head_commit,
            "task_ref" => review_target.task_ref,
            "phase_ref" => review_target.phase_ref.to_s
          },
          "phase_runtime" => phase_runtime_form,
          "slot_paths" => workspace.slot_paths.transform_keys(&:to_s).transform_values(&:to_s)
        }
        docs_context = docs_context_form(
          workspace: workspace,
          task: task,
          task_packet: task_packet,
          phase_runtime: phase_runtime,
          command_intent: command_intent
        )
        payload["docs_context"] = docs_context if docs_context
        payload["project_key"] = project_key if project_key
        payload["command_intent"] = command_intent.to_s if command_intent
        payload
      end

      def docs_context_form(workspace:, task:, task_packet:, phase_runtime:, command_intent: nil)
        return nil unless docs_context_relevant?(phase_runtime: phase_runtime, command_intent: command_intent)
        docs_config = phase_runtime.respond_to?(:docs_config) ? phase_runtime.docs_config : nil
        return nil unless docs_config.is_a?(Hash)

        repo_root = docs_repo_root(workspace: workspace, docs_config: docs_config)
        return nil unless repo_root

        docs_index = A3::Domain::ProjectDocsIndex.load(repo_root: repo_root, docs_config: docs_config)
        context = A3::Domain::ProjectDocsImpactAnalyzer.new(docs_index: docs_index)
          .analyze(task: task, task_packet: task_packet, changed_files: changed_files_from_workspace(workspace))
          .request_form
        context.merge(
          "config_summary" => docs_config_summary(docs_config),
          "expected_actions" => expected_docs_actions(context),
          "impact_policy" => stringify_keys(docs_config["impactPolicy"] || docs_config[:impactPolicy] || {}),
          "language_policy" => language_policy_summary(docs_config),
          "traceability_refs" => docs_traceability_refs(task: task, task_packet: task_packet),
          "request_phase" => docs_context_phase(phase_runtime)
        )
      end

      def docs_context_relevant?(phase_runtime:, command_intent:)
        return true if command_intent&.to_sym == :decomposition

        phase = phase_runtime.phase.to_sym
        phase == :implementation || phase == :review
      end

      def docs_repo_root(workspace:, docs_config:)
        slot = docs_config["repoSlot"] || docs_config[:repoSlot]
        if slot
          slot_path = workspace.slot_paths[slot.to_sym]
          return slot_path.to_s if slot_path
        elsif workspace.slot_paths.one?
          return workspace.slot_paths.values.first.to_s
        end

        workspace.root_path.to_s
      end

      def docs_config_summary(docs_config)
        categories = stringify_keys(docs_config["categories"] || docs_config[:categories] || {})
        authorities = stringify_keys(docs_config["authorities"] || docs_config[:authorities] || {})
        {
          "root" => docs_config["root"] || docs_config[:root],
          "repo_slot" => docs_config["repoSlot"] || docs_config[:repoSlot],
          "index" => docs_config["index"] || docs_config[:index],
          "policy" => docs_config["policy"] || docs_config[:policy],
          "categories" => categories.keys.sort,
          "authorities" => authorities.keys.sort
        }.compact
      end

      def expected_docs_actions(context)
        case context.fetch("decision", "no")
        when "yes"
          actions = ["update_or_confirm_candidate_docs", "record_docs_impact_evidence"]
          actions << "respect_mirror_policy" unless Array(context["mirror_debt"]).empty?
          actions
        when "maybe"
          ["decide_docs_impact", "record_docs_impact_evidence"]
        else
          ["record_no_docs_impact_if_relevant"]
        end
      end

      def language_policy_summary(docs_config)
        impact_policy = docs_config["impactPolicy"] || docs_config[:impactPolicy] || {}
        languages = docs_config["languages"] || docs_config[:languages] || {}
        {
          "primary" => impact_policy["primaryLanguage"] || impact_policy[:primaryLanguage] || languages["primary"] || languages[:primary],
          "mirrors" => impact_policy["mirrorLanguages"] || impact_policy[:mirrorLanguages] || languages["mirrors"] || languages[:mirrors],
          "mirror_policy" => impact_policy["mirrorPolicy"] || impact_policy[:mirrorPolicy] || languages["policy"] || languages[:policy]
        }.compact
      end

      def docs_traceability_refs(task:, task_packet:)
        text = [task_packet.title, task_packet.description].join("\n")
        refs = [task.ref, task.parent_ref, *task.child_refs]
        refs.concat(text.scan(/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#\d+/))
        refs.concat(text.scan(/[A-Z][A-Za-z0-9_-]*#\d+/))
        refs.compact.map(&:to_s).reject(&:empty?).uniq
      end

      def docs_context_phase(phase_runtime)
        return "parent_review" if phase_runtime.phase.to_sym == :review && phase_runtime.task_kind.to_sym == :parent

        phase_runtime.phase.to_s
      end

      def project_prompt_form(skill:, phase_runtime:, task_packet:, prior_review_feedback:)
        prompt_config = phase_runtime.respond_to?(:project_prompt_config) ? phase_runtime.project_prompt_config : nil
        return nil unless prompt_config && !prompt_config.empty?

        prompt_phase = prompt_phase_for(phase_runtime: phase_runtime, prior_review_feedback: prior_review_feedback)
        effective_prompt_phase, phase_config = prompt_config.phase_resolution(prompt_phase)
        repo_slots = repo_prompt_slots(phase_runtime, task_packet)
        layers = []
        layers << prompt_layer("a2o_core_instruction", "A2O core instruction", skill.to_s) if skill
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
          repo_slot_config = prompt_config.repo_slot_addon_phase(repo_slot, prompt_phase)
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
        repo_slot = repo_slots.one? ? repo_slots.first : nil
        layers << prompt_layer(
          "ticket_phase_instruction",
          "ticket #{task_packet.ref}",
          ticket_instruction_content(task_packet)
        )
        {
          "profile" => prompt_phase,
          "effective_profile" => effective_prompt_phase,
          "fallback_profile" => (effective_prompt_phase if effective_prompt_phase != prompt_phase),
          "repo_slot" => repo_slot,
          "repo_slots" => repo_slots,
          "project_package_schema_version" => "1",
          "layers" => layers,
          "composed_instruction" => layers.map { |layer| "## #{layer.fetch("title")}\n#{layer.fetch("content")}" }.join("\n\n")
        }
      end

      def prompt_phase_for(phase_runtime:, prior_review_feedback:)
        phase_name = phase_runtime.phase.to_s
        return "implementation_rework" if phase_name == "implementation" && prior_review_feedback
        return "parent_review" if phase_name == "review" && phase_runtime.task_kind.to_sym == :parent

        phase_name
      end

      def repo_prompt_slots(phase_runtime, task_packet)
        repo_scope = phase_runtime.repo_scope.to_s
        return [] if repo_scope.empty?
        return [repo_scope] unless repo_scope == "both"

        Array(task_packet.edit_scope).map(&:to_s).reject(&:empty?).uniq
      end

      def prompt_layer(kind, title, content)
        {
          "kind" => kind,
          "title" => title,
          "content" => content
        }
      end

      def ticket_instruction_content(task_packet)
        [
          "Task: #{task_packet.ref}",
          "Title: #{task_packet.title}",
          "Description:",
          task_packet.description.to_s
        ].join("\n")
      end

      def write_request(skill:, workspace:, task:, run:, phase_runtime:, task_packet:, command_intent: nil, prior_review_feedback: nil)
        request_dir = metadata_dir(workspace)
        FileUtils.mkdir_p(request_dir)
        form = request_form(skill: skill, workspace: workspace, task: task, run: run, phase_runtime: phase_runtime, task_packet: task_packet, command_intent: command_intent, prior_review_feedback: prior_review_feedback)
        request_dir.join("worker-request.json").write(
          JSON.pretty_generate(form)
        )
        form
      end

      def project_prompt_metadata(request_form)
        project_prompt = request_form.dig("phase_runtime", "project_prompt")
        return nil unless project_prompt.is_a?(Hash)

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
          "effective_profile" => project_prompt["effective_profile"].to_s,
          "fallback_profile" => project_prompt["fallback_profile"].to_s,
          "repo_slot" => project_prompt["repo_slot"].to_s,
          "repo_slots" => Array(project_prompt["repo_slots"]).map(&:to_s).reject(&:empty?),
          "project_package_schema_version" => project_prompt["project_package_schema_version"].to_s,
          "layers" => layers,
          "composed_instruction_sha256" => Digest::SHA256.hexdigest(composed),
          "composed_instruction_bytes" => composed.bytesize
        }
      end

      def load_result(result_path)
        return nil unless result_path.exist?

        raw_content = result_path.read
        parsed = JSON.parse(raw_content)
        return parsed unless parsed.nil?

        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker result schema invalid",
          failing_command: "worker_result_schema",
          observed_state: "invalid_worker_result",
          diagnostics: { "validation_errors" => ["worker result payload must be an object"] },
          response_bundle: { "raw" => raw_content }
        )
      rescue JSON::ParserError
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker result json invalid",
          failing_command: "worker_result_json",
          observed_state: "invalid_worker_result",
          diagnostics: { "validation_errors" => ["worker result file is not valid JSON"] },
          response_bundle: { "raw" => raw_content }
        )
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end

      def missing_result
        invalid_result("worker result file is missing", {})
      end

      def build_execution_result(worker_response, workspace:, expected_task_ref:, expected_run_ref:, expected_phase:, expected_task_kind: nil, canonical_changed_files: nil)
        return nil if worker_response.nil?

        unless worker_response.is_a?(Hash)
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "worker result schema invalid",
            failing_command: "worker_result_schema",
            observed_state: "invalid_worker_result",
            diagnostics: { "validation_errors" => ["worker result payload must be an object"] },
            response_bundle: worker_response
          )
        end
        worker_response = mutable_worker_response(worker_response)
        identity_corrections = canonicalize_worker_identity!(
          worker_response,
          expected_task_ref: expected_task_ref,
          expected_run_ref: expected_run_ref,
          expected_phase: expected_phase
        )
        validation_errors = validate_worker_response(
          worker_response,
          workspace: workspace,
          expected_task_ref: expected_task_ref,
          expected_run_ref: expected_run_ref,
          expected_phase: expected_phase,
          expected_task_kind: expected_task_kind
        )
        unless validation_errors.empty?
          A3::Infra::WorkspaceTraceLogger.log(
            workspace_root: workspace.root_path,
            event: "worker_gateway.result.invalid",
            payload: {
              "task_ref" => expected_task_ref,
              "run_ref" => expected_run_ref,
              "phase" => expected_phase.to_s,
              "validation_errors" => validation_errors
            }
          )
          return A3::Application::ExecutionResult.new(
            success: false,
            summary: "worker result schema invalid",
            failing_command: "worker_result_schema",
            observed_state: "invalid_worker_result",
            diagnostics: { "validation_errors" => validation_errors },
            response_bundle: worker_response
          )
        end

        diagnostics = worker_response["diagnostics"].is_a?(Hash) ? worker_response["diagnostics"].dup : {}
        diagnostics["canonicalized_identity"] = identity_corrections unless identity_corrections.empty?
        response_bundle = canonicalize_response_bundle(
          worker_response,
          workspace: workspace,
          expected_phase: expected_phase,
          diagnostics: diagnostics,
          canonical_changed_files: canonical_changed_files
        )

        A3::Application::ExecutionResult.new(
          success: worker_response.fetch("success"),
          summary: worker_response.fetch("summary"),
          failing_command: worker_response["failing_command"],
          observed_state: worker_response["observed_state"],
          diagnostics: diagnostics,
          response_bundle: response_bundle
        )
      end

      private

      def invalid_result(message, raw)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker result schema invalid",
          failing_command: "worker_result_schema",
          observed_state: "invalid_worker_result",
          diagnostics: { "validation_errors" => [message] },
          response_bundle: raw.is_a?(Hash) ? raw : { "raw" => raw }
        )
      end

      def mutable_worker_response(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), result|
            result[key] = mutable_worker_response(entry)
          end
        when Array
          value.map { |entry| mutable_worker_response(entry) }
        else
          value
        end
      end

      def workspace_automation_env(workspace_root)
        {
          "AUTOMATION_ISSUE_WORKSPACE" => workspace_root,
          "MAVEN_REPO_LOCAL" => File.join(workspace_root, ".work", "m2", "repository")
        }
      end

      def canonicalize_response_bundle(worker_response, workspace:, expected_phase:, diagnostics:, canonical_changed_files: nil)
        return worker_response unless expected_phase.to_s == "implementation" && worker_response["success"] == true

        canonical_changed_files ||= changed_files_from_workspace(workspace)
        worker_changed_files = worker_response["changed_files"]
        if worker_changed_files != canonical_changed_files
          diagnostics["worker_changed_files"] = worker_changed_files
          diagnostics["canonical_changed_files"] = canonical_changed_files
        end

        worker_response.merge("changed_files" => canonical_changed_files)
      end

      def canonicalize_worker_identity!(worker_response, expected_task_ref:, expected_run_ref:, expected_phase:)
        corrections = {}
        {
          "task_ref" => expected_task_ref,
          "run_ref" => expected_run_ref,
          "phase" => expected_phase.to_s
        }.each do |key, expected|
          next unless worker_response.key?(key)
          next if worker_response[key] == expected

          corrections[key] = {
            "provided" => worker_response[key],
            "canonical" => expected
          }
          worker_response[key] = expected
        end
        corrections
      end

      def validate_worker_response(worker_response, workspace:, expected_task_ref:, expected_run_ref:, expected_phase:, expected_task_kind: nil)
        normalize_worker_response!(worker_response, workspace: workspace, expected_phase: expected_phase, expected_task_kind: expected_task_kind)
        implementation_phase = expected_phase.to_s == "implementation"
        parent_review = parent_review?(expected_phase: expected_phase, expected_task_kind: expected_task_kind)
        errors = []
        errors << "success must be true or false" unless [true, false].include?(worker_response["success"])
        errors << "summary must be a string" unless worker_response["summary"].is_a?(String)
        if worker_response.key?("task_ref") && worker_response["task_ref"] != expected_task_ref
          errors << "task_ref must match the worker request"
        end
        if worker_response.key?("run_ref") && worker_response["run_ref"] != expected_run_ref
          errors << "run_ref must match the worker request"
        end
        if worker_response.key?("phase") && worker_response["phase"] != expected_phase.to_s
          errors << "phase must match the worker request"
        end
        if worker_response.key?("review_disposition")
          disposition = worker_response["review_disposition"]
          unless disposition.is_a?(Hash)
            errors << "review_disposition must be an object when present"
            return errors
          end

          %w[kind repo_scope summary description finding_key].each do |key|
            errors << "review_disposition.#{key} must be present" unless disposition[key].is_a?(String)
          end
          if parent_review
            valid_kinds = %w[completed follow_up_child blocked]
            valid_repo_scopes = valid_review_disposition_repo_scopes(workspace, include_unresolved: true)
            unless valid_kinds.include?(disposition["kind"])
              errors << "review_disposition.kind must be one of #{valid_kinds.join(', ')}"
            end
            unless valid_repo_scopes.include?(disposition["repo_scope"])
              errors << "review_disposition.repo_scope must be one of #{valid_repo_scopes.join(', ')}"
            end
            if worker_response["success"] == true && disposition["kind"] != "completed"
              errors << "review_disposition.kind must be completed when success is true for parent review"
            end
          elsif implementation_phase
            valid_repo_scopes = valid_review_disposition_repo_scopes(workspace, include_unresolved: false)
            errors << "review_disposition.kind must be completed for implementation evidence" unless disposition["kind"] == "completed"
            unless valid_repo_scopes.include?(disposition["repo_scope"])
              errors << "review_disposition.repo_scope must be one of #{valid_repo_scopes.join(', ')}"
            end
          end
        end
        if worker_response.fetch("success", nil) == false &&
           worker_response["rework_required"] != true &&
           !clarification_request_present?(worker_response) &&
           !worker_response["failing_command"].is_a?(String)
          errors << "failing_command must be a string when success is false unless rework_required is true"
        elsif worker_response.key?("failing_command") && !worker_response["failing_command"].nil? && !worker_response["failing_command"].is_a?(String)
          errors << "failing_command must be a string when present"
        end
        if worker_response.key?("observed_state") && !worker_response["observed_state"].nil? && !worker_response["observed_state"].is_a?(String)
          errors << "observed_state must be a string when present"
        elsif worker_response.fetch("success", nil) == false && !clarification_request_present?(worker_response) && !worker_response["observed_state"].is_a?(String)
          errors << "observed_state must be a string when success is false"
        end
        diagnostics = worker_response["diagnostics"]
        if worker_response.key?("diagnostics") && !diagnostics.is_a?(Hash)
          errors << "diagnostics must be an object"
        end
        validate_skill_feedback(worker_response["skill_feedback"]).each { |error| errors << error } if worker_response.key?("skill_feedback")
        validate_clarification_request(worker_response["clarification_request"], success: worker_response["success"]).each { |error| errors << error } if worker_response.key?("clarification_request")
        validate_docs_impact(worker_response["docs_impact"]).each { |error| errors << error } if worker_response.key?("docs_impact")
        unless [true, false].include?(worker_response["rework_required"])
          errors << "rework_required must be true or false"
        end
        if worker_response.key?("changed_files")
          changed_files = worker_response["changed_files"]
          unless changed_files.nil? || changed_files.is_a?(Hash)
            errors << "changed_files must be an object when present"
            return errors
          end
          return errors if changed_files.nil?

          changed_files.each do |slot_name, files|
            errors << "changed_files slot names must be strings" unless slot_name.is_a?(String)
            unless files.is_a?(Array) && files.all? { |entry| entry.is_a?(String) }
              errors << "changed_files for #{slot_name} must be an array of strings"
            end
          end
        elsif implementation_phase && worker_response.fetch("success", nil) == true
          errors << "changed_files must be present for implementation success"
        end
        if implementation_phase && worker_response.fetch("success", nil) == true && !worker_response.key?("review_disposition")
          errors << "review_disposition must be present for implementation success"
        end
        errors
      end

      def normalize_worker_response!(worker_response, workspace:, expected_phase:, expected_task_kind:)
        disposition = worker_response["review_disposition"]
        normalize_skill_feedback!(worker_response)
        normalize_parent_review_success!(worker_response, workspace: workspace) if parent_review?(expected_phase: expected_phase, expected_task_kind: expected_task_kind)
        disposition = worker_response["review_disposition"]
        return unless disposition.is_a?(Hash)

        disposition["repo_scope"] = @repo_scope_aliases.fetch(disposition["repo_scope"], disposition["repo_scope"])
      end

      def parent_review?(expected_phase:, expected_task_kind:)
        expected_phase.to_s == "review" && (expected_task_kind.nil? || expected_task_kind.to_sym == :parent)
      end

      def normalize_parent_review_success!(worker_response, workspace:)
        return unless worker_response["success"] == true
        return unless worker_response["rework_required"] == false

        disposition = worker_response["review_disposition"]
        return if disposition.is_a?(Hash) && present_string?(disposition["kind"]) && disposition["kind"] != "completed"

        normalized_disposition = disposition.is_a?(Hash) ? disposition.dup : {}
        normalized_disposition["kind"] = "completed"
        normalized_disposition["repo_scope"] = default_parent_review_repo_scope(workspace) unless present_string?(normalized_disposition["repo_scope"])
        normalized_disposition["summary"] = worker_response["summary"] unless present_string?(normalized_disposition["summary"])
        normalized_disposition["description"] = worker_response["summary"] unless present_string?(normalized_disposition["description"])
        normalized_disposition["finding_key"] = "parent-review-completed" unless present_string?(normalized_disposition["finding_key"])
        worker_response["review_disposition"] = normalized_disposition
      end

      def default_parent_review_repo_scope(workspace)
        valid_review_disposition_repo_scopes(workspace, include_unresolved: true)
          .reject { |scope| scope == "unresolved" }
          .fetch(0, "unresolved")
      end

      def normalize_skill_feedback!(worker_response)
        value = worker_response["skill_feedback"]
        entries =
          case value
          when Hash
            [value]
          when Array
            value
          else
            return
          end

        entries.each do |entry|
          next unless entry.is_a?(Hash)

          entry["repo_scope"] = @repo_scope_aliases.fetch(entry["repo_scope"], entry["repo_scope"]) if entry["repo_scope"].is_a?(String)
        end
      end

      def validate_skill_feedback(value)
        return [] if value.nil?

        entries =
          case value
          when Hash
            [value]
          when Array
            value
          else
            return ["skill_feedback must be an object, array of objects, or null when present"]
          end

        entries.each_with_index.flat_map do |entry, index|
          validate_skill_feedback_entry(entry, index)
        end
      end

      def validate_skill_feedback_entry(entry, index)
        prefix = "skill_feedback[#{index}]"
        return ["#{prefix} must be an object"] unless entry.is_a?(Hash)

        errors = []
        errors << "#{prefix}.category must be a string" unless entry["category"].is_a?(String)
        errors << "#{prefix}.summary must be a string" unless entry["summary"].is_a?(String)
        errors << "#{prefix}.proposal must be an object" unless entry["proposal"].is_a?(Hash)
        if entry["proposal"].is_a?(Hash) && !entry.dig("proposal", "target").is_a?(String)
          errors << "#{prefix}.proposal.target must be a string"
        elsif entry["proposal"].is_a?(Hash) && !valid_skill_feedback_targets.include?(entry.dig("proposal", "target"))
          errors << "#{prefix}.proposal.target must be one of #{valid_skill_feedback_targets.join(', ')}"
        end
        if entry.key?("state") && !A3::Domain::SkillFeedback.states.include?(entry["state"])
          errors << "#{prefix}.state must be one of #{A3::Domain::SkillFeedback.states.join(', ')}"
        end
        %w[schema phase repo_scope skill_path confidence].each do |field|
          errors << "#{prefix}.#{field} must be a string when present" if entry.key?(field) && !entry[field].is_a?(String)
        end
        errors << "#{prefix}.evidence must be an object when present" if entry.key?("evidence") && !entry["evidence"].is_a?(Hash)
        errors
      end

      def validate_clarification_request(value, success:)
        return [] if value.nil?
        return ["clarification_request must be an object when present"] unless value.is_a?(Hash)

        errors = []
        errors << "clarification_request must only be present when success is false" if success == true
        errors << "clarification_request.question must be a non-empty string" unless present_string?(value["question"])
        %w[context recommended_option impact].each do |field|
          errors << "clarification_request.#{field} must be a string when present" if value.key?(field) && !value[field].nil? && !value[field].is_a?(String)
        end
        if value.key?("options")
          options = value["options"]
          unless options.is_a?(Array) && options.all? { |entry| entry.is_a?(String) && !entry.strip.empty? }
            errors << "clarification_request.options must be an array of non-empty strings"
          end
        end
        errors
      end

      def validate_docs_impact(value)
        return [] if value.nil?
        return ["docs_impact must be an object when present"] unless value.is_a?(Hash)

        errors = []
        if value.key?("disposition")
          dispositions = %w[yes no maybe]
          errors << "docs_impact.disposition must be one of #{dispositions.join(', ')}" unless dispositions.include?(value["disposition"])
        else
          errors << "docs_impact.disposition must be present"
        end
        validate_optional_string_array(value, "categories", "docs_impact.categories").each { |error| errors << error }
        validate_optional_string_array(value, "updated_docs", "docs_impact.updated_docs").each { |error| errors << error }
        validate_optional_string_array(value, "updated_authorities", "docs_impact.updated_authorities").each { |error| errors << error }
        validate_optional_string_array(value, "matched_rules", "docs_impact.matched_rules").each { |error| errors << error }
        validate_optional_string(value, "review_disposition", "docs_impact.review_disposition").each { |error| errors << error }
        validate_docs_impact_skipped_docs(value["skipped_docs"]).each { |error| errors << error } if value.key?("skipped_docs")
        if value.key?("traceability")
          errors << "docs_impact.traceability must be an object when present" unless value["traceability"].is_a?(Hash)
        end
        errors
      end

      def validate_optional_string_array(value, key, field)
        return [] unless value.key?(key)

        entries = value[key]
        return [] if entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) }

        ["#{field} must be an array of strings when present"]
      end

      def validate_optional_string(value, key, field)
        return [] unless value.key?(key)
        return [] if value[key].nil? || value[key].is_a?(String)

        ["#{field} must be a string when present"]
      end

      def validate_docs_impact_skipped_docs(value)
        return ["docs_impact.skipped_docs must be an array of objects when present"] unless value.is_a?(Array)

        value.each_with_index.flat_map do |entry, index|
          prefix = "docs_impact.skipped_docs[#{index}]"
          next ["#{prefix} must be an object"] unless entry.is_a?(Hash)

          errors = []
          errors << "#{prefix}.path must be a string" unless entry["path"].is_a?(String)
          errors << "#{prefix}.reason must be a string" unless entry["reason"].is_a?(String)
          errors
        end
      end

      def clarification_request_present?(worker_response)
        worker_response["clarification_request"].is_a?(Hash)
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def stringify_keys(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, entry), memo| memo[key.to_s] = entry }
      end

      def normalize_repo_scope_aliases(repo_scope_aliases)
        raise A3::Domain::ConfigurationError, "repo_scope_aliases must be an object" unless repo_scope_aliases.is_a?(Hash)

        repo_scope_aliases.each_with_object({}) do |(from, to), normalized|
          unless from.is_a?(String) && !from.empty? && to.is_a?(String) && !to.empty?
            raise A3::Domain::ConfigurationError, "repo_scope_aliases keys and values must be non-empty strings"
          end

          normalized[from] = to
        end
      end

      def valid_skill_feedback_targets
        A3::Domain::SkillFeedback.targets
      end

      def normalize_configured_review_disposition_repo_scopes(scopes)
        return nil if scopes.nil?
        unless scopes.is_a?(Array) && scopes.all? { |scope| scope.is_a?(String) && !scope.empty? }
          raise A3::Domain::ConfigurationError, "review_disposition_repo_scopes must be an array of non-empty strings"
        end

        scopes.uniq
      end

      def valid_review_disposition_repo_scopes(workspace, include_unresolved:)
        scopes = @review_disposition_repo_scopes || inferred_review_disposition_repo_scopes(workspace)
        scopes = scopes.reject { |scope| scope == "unresolved" } unless include_unresolved
        scopes = scopes + ["unresolved"] if include_unresolved
        scopes.uniq
      end

      def inferred_review_disposition_repo_scopes(workspace)
        workspace.slot_paths.keys.map(&:to_s).reject(&:empty?).uniq
      end

      def changed_files_from_workspace(workspace)
        workspace.slot_paths.each_with_object({}) do |(slot_name, slot_path), entries|
          next unless git_repo?(slot_path)

          changed_paths = git_changed_paths(slot_path)
          next if changed_paths.empty?

          entries[slot_name.to_s] = changed_paths
        end
      end

      def git_repo?(slot_path)
        _stdout, _stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "rev-parse", "--is-inside-work-tree")
        status.success?
      end

      def git_changed_paths(slot_path)
        stdout, stderr, status = Open3.capture3(
          "git", "-C", slot_path.to_s, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3"
        )
        raise A3::Domain::ConfigurationError, "git status failed: #{stderr}" unless status.success?

        stdout.each_line.map do |line|
          path = line[3..]&.strip
          next if path.nil? || path.empty?

          path.include?(" -> ") ? path.split(" -> ", 2).last : path
        end.compact.uniq.sort
      end
    end
  end
end
