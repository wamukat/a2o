# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "a3/domain/branch_namespace"
require "a3/infra/local_git_workspace_backend"
require "a3/infra/workspace_trace_logger"

module A3
  module Infra
    class LocalWorkspaceProvisioner
      IGNORED_REPO_SOURCE_ENTRIES = %w[.git .a3 .work target node_modules].freeze

      def initialize(base_dir:, repo_sources: {}, git_workspace_backend: A3::Infra::LocalGitWorkspaceBackend.new, branch_namespace: A3::Domain::BranchNamespace.from_env)
        @base_dir = Pathname(base_dir)
        @repo_sources = repo_sources.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
        @git_workspace_backend = git_workspace_backend
        @branch_namespace = A3::Domain::BranchNamespace.normalize(branch_namespace)
      end

      def call(task:, workspace_plan:, artifact_owner:, bootstrap_marker:)
        ensure_parent_workspace_slots!(task: task, workspace_plan: workspace_plan, artifact_owner: artifact_owner)
        root_path = workspace_root(task, workspace_plan.workspace_kind, artifact_owner)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: root_path,
          event: "workspace_provision.start",
          payload: {
            "task_ref" => task.ref,
            "workspace_kind" => workspace_plan.workspace_kind.to_s,
            "source_type" => workspace_plan.source_descriptor.source_type.to_s,
            "source_ref" => workspace_plan.source_descriptor.ref
          }
        )
        slot_paths = materialize_slot_paths(
          root_path,
          task.ref,
          workspace_plan,
          artifact_owner,
          bootstrap_marker
        )
        write_metadata(root_path, task.ref, workspace_plan)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: root_path,
          event: "workspace_provision.finish",
          payload: {
            "task_ref" => task.ref,
            "workspace_kind" => workspace_plan.workspace_kind.to_s,
            "slots" => slot_paths.transform_values(&:to_s)
          }
        )

        A3::Domain::PreparedWorkspace.new(
          workspace_kind: workspace_plan.workspace_kind,
          root_path: root_path,
          source_descriptor: workspace_plan.source_descriptor,
          slot_paths: slot_paths
        )
      end

      def quarantine_task(task_ref:)
        source_root = task_workspace_root(task_ref, allow_nested_lookup: true)
        return nil unless source_root.exist?

        quarantine_root = base_dir.join("quarantine", slugify(task_ref))
        FileUtils.rm_rf(quarantine_root)
        FileUtils.mkdir_p(quarantine_root.parent)
        if git_worktree_slots(source_root).empty?
          FileUtils.mv(source_root, quarantine_root)
        else
          normalize_git_worktree_slots_for_quarantine!(source_root)
          FileUtils.mv(source_root, quarantine_root)
        end
        quarantine_root.to_s
      end

      def cleanup_task(task_ref:, scopes:, dry_run: false, parent_ref: nil, workspace_ref: nil, parent_workspace_ref: nil)
        task_root = cleanup_task_root(
          task_ref: task_ref,
          parent_ref: parent_ref,
          workspace_ref: workspace_ref,
          parent_workspace_ref: parent_workspace_ref
        )
        cleaned_paths = Array(scopes).map(&:to_sym).each_with_object([]) do |scope, paths|
          path = cleanup_scope_path(task_root, scope)
          next unless path&.exist?

          remove_path!(path, dry_run: dry_run)
          paths << path.to_s
        end

        cleanup_empty_workspace_root!(task_root, dry_run: dry_run)
        cleaned_paths.freeze
      end

      private

      attr_reader :base_dir

      def workspaces_root
        base_dir.join("workspaces")
      end

      def cleanup_task_root(task_ref:, parent_ref:, workspace_ref:, parent_workspace_ref:)
        if parent_ref
          return task_workspace_root(
            task_ref,
            parent_ref: parent_ref,
            parent_workspace_ref: parent_workspace_ref,
            allow_nested_lookup: false
          )
        end

        task_workspace_root(workspace_ref || task_ref, allow_nested_lookup: false)
      end

      def task_workspace_root(task_ref, parent_ref: nil, parent_workspace_ref: nil, allow_nested_lookup: false)
        task_slug = slugify(task_ref)
        if parent_ref
          parent_slug = slugify(parent_workspace_ref || parent_ref)
          return workspaces_root.join(parent_slug, "children", task_slug)
        end

        direct = workspaces_root.join(task_slug)
        return direct unless allow_nested_lookup
        return direct if direct.exist?

        child_roots = workspaces_root.glob("*/children/#{task_slug}")
        child_roots.first || direct
      end

      def workspace_root(task, workspace_kind, artifact_owner)
        if child_owned_by_parent?(task, artifact_owner)
          workspaces_root.join(slugify(parent_workspace_ref_for(artifact_owner.owner_ref)), "children", slugify(task.ref), workspace_kind.to_s)
        else
          workspaces_root.join(slugify(task.ref), workspace_kind.to_s)
        end
      end

      def ensure_parent_workspace_slots!(task:, workspace_plan:, artifact_owner:)
        return unless child_owned_by_parent?(task, artifact_owner)

        parent_source_ref = parent_integration_ref(artifact_owner.owner_ref)
        parent_plan = A3::Domain::WorkspacePlan.new(
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: parent_source_ref,
            task_ref: artifact_owner.owner_ref
          ),
          slot_requirements: workspace_plan.slot_requirements
        )
        parent_root = workspaces_root.join(slugify(parent_workspace_ref_for(artifact_owner.owner_ref)), "runtime_workspace")
        parent_owner = A3::Domain::ArtifactOwner.new(
          owner_ref: artifact_owner.owner_ref,
          owner_scope: :parent,
          snapshot_version: parent_source_ref
        )
        materialize_slot_paths(parent_root, artifact_owner.owner_ref, parent_plan, parent_owner, nil)
        write_metadata(parent_root, artifact_owner.owner_ref, parent_plan)
      end

      def materialize_slot_paths(root_path, task_ref, workspace_plan, artifact_owner, bootstrap_marker)
        FileUtils.mkdir_p(root_path)
        workspace_plan.slot_requirements.each_with_object({}) do |requirement, slot_paths|
          source_root = repo_source_for(requirement.repo_slot)
          slot_path = root_path.join(repo_slot_directory(requirement.repo_slot, source_root))
          if slot_paths.value?(slot_path)
            raise A3::Domain::ConfigurationError,
                  "Repo source basename collision for #{source_root.basename}; materialized workspace directories must be unique"
          end
          ready = slot_ready?(slot_path, source_root, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker)
          unless ready
            A3::Infra::WorkspaceTraceLogger.log(
              workspace_root: root_path,
              event: "workspace_provision.rematerialize_slot.start",
              payload: {
                "task_ref" => task_ref,
                "workspace_kind" => workspace_plan.workspace_kind.to_s,
                "repo_slot" => requirement.repo_slot.to_s,
                "source_root" => source_root.to_s,
                "source_ref" => workspace_plan.source_descriptor.ref
              }
            )
            rematerialize_slot!(slot_path, source_root, workspace_plan, requirement.repo_slot)
            A3::Infra::WorkspaceTraceLogger.log(
              workspace_root: root_path,
              event: "workspace_provision.rematerialize_slot.finish",
              payload: {
                "task_ref" => task_ref,
                "workspace_kind" => workspace_plan.workspace_kind.to_s,
                "repo_slot" => requirement.repo_slot.to_s,
                "slot_path" => slot_path.to_s
              }
            )
          end
          write_slot_metadata(slot_path, source_root, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker)
          slot_paths[requirement.repo_slot] = slot_path
        end
      end

      def slot_ready?(slot_path, source_root, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker)
        return false if force_fresh_ticket_workspace?(workspace_plan)

        metadata_path = slot_metadata_path(slot_path)
        materialized_path = materialized_marker_path(slot_path)
        return false unless metadata_path.exist? && materialized_path.exist?

        metadata = JSON.parse(metadata_path.read)
        materialized = JSON.parse(materialized_path.read)
        checkout_ready =
          if git_repo_source?(source_root)
            @git_workspace_backend.ready?(source_root: source_root, destination: slot_path, ref: workspace_plan.source_descriptor.ref)
          else
            head_path = checkout_head_path(slot_path)
            head_path.exist? && head_path.read == "#{workspace_plan.source_descriptor.ref}\n"
          end
        metadata == slot_metadata(slot_path, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker) &&
          materialized == materialized_marker(workspace_plan) &&
          checkout_ready
      end

      def rematerialize_slot!(slot_path, source_root, workspace_plan, repo_slot)
        FileUtils.rm_rf(slot_path)
        if git_repo_source?(source_root)
          @git_workspace_backend.materialize(
            source_root: source_root,
            destination: slot_path,
            ref: workspace_plan.source_descriptor.ref,
            create_branch_if_missing: create_git_branch_if_missing?(workspace_plan),
            reset_branch_to: reset_branch_target_for(workspace_plan)
          )
        else
          FileUtils.mkdir_p(slot_path)
          copy_repo_source!(source_root, slot_path)
        end
      end

      def repo_source_for(repo_slot)
        @repo_sources.fetch(repo_slot.to_sym)
      rescue KeyError
        raise A3::Domain::ConfigurationError, "Missing repo source for #{repo_slot}"
      end

      def copy_repo_source!(source_root, slot_path)
        raise A3::Domain::ConfigurationError, "Missing repo source directory: #{source_root}" unless source_root.directory?

        source_root.children.each do |entry|
          next if ignored_repo_source_entry?(entry)

          copy_repo_source_entry!(entry, slot_path.join(entry.basename))
        end
      end

      def copy_repo_source_entry!(source_entry, destination_entry)
        if source_entry.symlink?
          FileUtils.ln_s(File.readlink(source_entry), destination_entry)
        elsif source_entry.directory?
          FileUtils.mkdir_p(destination_entry)
          source_entry.children.each do |child|
            next if ignored_repo_source_entry?(child)

            copy_repo_source_entry!(child, destination_entry.join(child.basename))
          end
        else
          FileUtils.copy_entry(source_entry, destination_entry)
        end
      end

      def ignored_repo_source_entry?(entry)
        IGNORED_REPO_SOURCE_ENTRIES.include?(entry.basename.to_s)
      end

      def write_slot_metadata(slot_path, source_root, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker)
        metadata_dir = slot_metadata_dir(slot_path)
        FileUtils.mkdir_p(metadata_dir)
        slot_metadata_path(slot_path).write(
          JSON.pretty_generate(slot_metadata(slot_path, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker))
        )
        materialized_marker_path(slot_path).write(
          JSON.pretty_generate(materialized_marker(workspace_plan))
        )
        unless git_repo_source?(source_root)
          FileUtils.mkdir_p(slot_path.join(".git"))
          checkout_head_path(slot_path).write("#{workspace_plan.source_descriptor.ref}\n")
        end
      end

      def slot_metadata(slot_path, task_ref, workspace_plan, requirement, artifact_owner, bootstrap_marker)
        {
          "task_ref" => task_ref,
          "workspace_kind" => workspace_plan.workspace_kind.to_s,
          "repo_slot" => requirement.repo_slot.to_s,
          "slot_path" => slot_path.to_s,
          "repo_source_root" => repo_source_for(requirement.repo_slot).to_s,
          "sync_class" => requirement.sync_class.to_s,
          "source_type" => workspace_plan.source_descriptor.source_type.to_s,
          "source_ref" => workspace_plan.source_descriptor.ref,
          "artifact_owner_ref" => artifact_owner.owner_ref,
          "artifact_owner_scope" => artifact_owner.owner_scope.to_s,
          "artifact_snapshot_version" => artifact_owner.snapshot_version,
          "bootstrap_marker" => bootstrap_marker
        }
      end

      def slot_metadata_path(slot_path)
        slot_metadata_dir(slot_path).join("slot.json")
      end

      def materialized_marker_path(slot_path)
        slot_metadata_dir(slot_path).join("materialized.json")
      end

      def slot_metadata_dir(slot_path)
        slot_path.parent.join(".a2o", "slots", slot_path.basename.to_s)
      end

      def checkout_head_path(slot_path)
        slot_path.join(".git", "HEAD")
      end

      def materialized_marker(workspace_plan)
        {
          "workspace_kind" => workspace_plan.workspace_kind.to_s,
          "source_type" => workspace_plan.source_descriptor.source_type.to_s,
          "source_ref" => workspace_plan.source_descriptor.ref
        }
      end

      def write_metadata(root_path, task_ref, workspace_plan)
        metadata_dir = root_path.join(".a2o")
        FileUtils.mkdir_p(metadata_dir)
        metadata_dir.join("workspace.json").write(
          JSON.pretty_generate(
            "task_ref" => task_ref,
            "workspace_kind" => workspace_plan.workspace_kind.to_s,
            "source_type" => workspace_plan.source_descriptor.source_type.to_s,
            "source_ref" => workspace_plan.source_descriptor.ref,
            "slot_requirements" => workspace_plan.slot_requirements.map do |requirement|
              {
                "repo_slot" => requirement.repo_slot.to_s,
                "sync_class" => requirement.sync_class.to_s
              }
            end
          )
        )
      end

      def slugify(task_ref)
        task_ref.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def repo_slot_directory(repo_slot, source_root = repo_source_for(repo_slot))
        source_root.basename.to_s
      end

      def git_repo_source?(source_root)
        @git_workspace_backend.git_repo?(source_root)
      end

      def create_git_branch_if_missing?(workspace_plan)
        %i[branch_head integration_record].include?(workspace_plan.source_descriptor.source_type.to_sym)
      end

      def reset_branch_target_for(workspace_plan)
        return nil unless force_fresh_ticket_workspace?(workspace_plan)

        "HEAD"
      end

      def force_fresh_ticket_workspace?(workspace_plan)
        workspace_plan.workspace_kind.to_sym == :ticket_workspace &&
          workspace_plan.source_descriptor.source_type.to_sym == :branch_head
      end

      def child_owned_by_parent?(task, artifact_owner)
        task.kind.to_sym == :child &&
          artifact_owner.owner_ref &&
          artifact_owner.owner_ref != task.ref
      end

      def parent_integration_ref(parent_ref)
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << slugify(parent_ref)
        parts.join("/")
      end

      def parent_workspace_ref_for(parent_ref)
        "#{parent_ref}-parent"
      end

      def git_worktree_slots(source_root)
        source_root.glob("**/.a2o/slots/*/slot.json").each_with_object([]) do |metadata_path, slots|
          metadata = JSON.parse(metadata_path.read)
          slot_path = Pathname(metadata.fetch("slot_path"))
          repo_slot = metadata.fetch("repo_slot").to_sym
          repo_source = repo_source_for(repo_slot)
          next unless git_repo_source?(repo_source)

          materialized =
            begin
              JSON.parse(materialized_marker_path(slot_path).read)
            rescue Errno::ENOENT, JSON::ParserError
              nil
            end
          slots << { repo_source: repo_source, slot_path: slot_path, metadata: metadata, materialized: materialized }
        rescue Errno::ENOENT, KeyError, A3::Domain::ConfigurationError, JSON::ParserError
          next
        end
      end

      def remove_git_worktree_slots!(source_root)
        git_worktree_slots(source_root).each do |entry|
          @git_workspace_backend.remove(
            source_root: entry.fetch(:repo_source),
            destination: entry.fetch(:slot_path)
          )
        end
      end

      def normalize_git_worktree_slots_for_quarantine!(source_root)
        git_worktree_slots(source_root).each do |entry|
          repo_source = entry.fetch(:repo_source)
          slot_path = entry.fetch(:slot_path)
          metadata = entry.fetch(:metadata)
          materialized = entry.fetch(:materialized)
          @git_workspace_backend.remove(
            source_root: repo_source,
            destination: slot_path
          )
          FileUtils.mkdir_p(slot_path)
          copy_repo_source!(repo_source, slot_path)
          metadata_dir = slot_metadata_dir(slot_path)
          FileUtils.mkdir_p(metadata_dir)
          slot_metadata_path(slot_path).write(JSON.pretty_generate(metadata)) if metadata
          materialized_marker_path(slot_path).write(JSON.pretty_generate(materialized)) if materialized
        end
      end

      def cleanup_scope_path(task_root, scope)
        case scope
        when :ticket_workspace, :runtime_workspace
          task_root.join(scope.to_s)
        when :quarantine
          base_dir.join("quarantine", task_root.basename.to_s)
        else
          raise A3::Domain::ConfigurationError, "Unknown cleanup scope: #{scope}"
        end
      end

      def remove_path!(path, dry_run:)
        return if dry_run

        FileUtils.rm_rf(path)
      end

      def cleanup_empty_workspace_root!(task_root, dry_run:)
        return if dry_run
        return unless task_root.exist?

        removable_entries = task_root.children.reject do |entry|
          %w[.a2o .a3].include?(entry.basename.to_s)
        end
        return unless removable_entries.empty?

        FileUtils.rm_rf(task_root)
      end
    end
  end
end
