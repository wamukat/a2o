# frozen_string_literal: true

require "open3"
require "pathname"

module A3
  module Operator
    module RerunWorkspaceSupport
      DEFAULT_TOP_LEVEL_NAMES = [".work", ".support"].freeze
      DEFAULT_REPO_LOCAL_NAMES = ["target", ".work", ".support"].freeze
      INTERNAL_PARENT_BRANCH_PREFIX = "a3/parent".freeze

      module_function

      def canonical_task_slug(task_ref)
        project, index = String(task_ref).split("#", 2)
        raise "Unsupported task ref: #{task_ref}" if project.to_s.empty? || index.to_s.empty?

        "#{project.downcase}-#{index}"
      end

      def compute_issue_workspace(root_dir:, project:, task_ref:)
        Pathname(root_dir).join(".work", "a3", "issues", project.downcase, canonical_task_slug(task_ref))
      end

      def compute_quarantine_root(root_dir:, project:, task_ref:, now:)
        Pathname(root_dir).join(
          ".work",
          "a3",
          "quarantine",
          project.downcase,
          canonical_task_slug(task_ref),
          now.utc.strftime("%Y%m%dT%H%M%SZ")
        )
      end

      def top_level_support_bridge?(issue_workspace:, path:)
        return false unless path.symlink?

        relative = path.relative_path_from(issue_workspace)
        return false unless relative.each_filename.to_a.size == 1
        return false if path.basename.to_s.start_with?(".")

        target = File.readlink(path.to_s)
        target.tr("\\", "/").start_with?(".support/")
      rescue Errno::EINVAL, Errno::ENOENT, ArgumentError
        false
      end

      def top_level_broken_support_bridges(issue_workspace)
        return [] unless issue_workspace.exist?

        issue_workspace.children.sort.filter do |child|
          next false if child.basename.to_s.start_with?(".")
          next false unless child.symlink?
          next false if child.exist?

          top_level_support_bridge?(issue_workspace: issue_workspace, path: child)
        end
      end

      def current_branch(repo_path)
        stdout, _stderr, status = Open3.capture3(
          "git",
          "-C",
          repo_path.to_s,
          "branch",
          "--show-current"
        )
        return nil unless status.success?

        value = stdout.strip
        value.empty? ? nil : value
      end

      def checked_out_internal_parent_branch?(repo_path)
        branch_name = current_branch(repo_path)
        return false if branch_name.nil?

        branch_name == INTERNAL_PARENT_BRANCH_PREFIX || branch_name.start_with?("#{INTERNAL_PARENT_BRANCH_PREFIX}/")
      end

      def collect_default_rerun_paths(issue_workspace:)
        return [] unless issue_workspace.exist?

        candidates = []
        DEFAULT_TOP_LEVEL_NAMES.each do |name|
          path = issue_workspace.join(name)
          candidates << path if path.exist? || path.symlink?
        end
        issue_workspace.children.sort.each do |child|
          next if child.basename.to_s.start_with?(".")

          if top_level_support_bridge?(issue_workspace: issue_workspace, path: child)
            candidates << child
            next
          end
          next unless child.directory?
          next unless child.join(".git").exist?

          if checked_out_internal_parent_branch?(child)
            candidates << child
            next
          end

          DEFAULT_REPO_LOCAL_NAMES.each do |name|
            path = child.join(name)
            candidates << path if path.exist? || path.symlink?
          end
        end
        candidates
      end
    end
  end
end

A3RerunWorkspaceSupport = A3::Operator::RerunWorkspaceSupport unless Object.const_defined?(:A3RerunWorkspaceSupport)
