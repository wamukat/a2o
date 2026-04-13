# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require "a3/operator/rerun_workspace_support"

module A3
  module Operator
    module RerunQuarantine
      QuarantinedPath = Struct.new(:source, :destination, keyword_init: true) do
        def to_h
          {
            "source" => source,
            "destination" => destination
          }
        end
      end

      module_function

      def ensure_allowed_relative_path(issue_workspace:, path:)
        relative = path.relative_path_from(issue_workspace)
        raise "path must not be issue workspace root: #{path}" if relative.to_s.empty? || relative.to_s == "."
        raise "path must not touch git metadata: #{path}" if relative.each_filename.include?(".git")

        parts = relative.each_filename.to_a
        if parts.size == 1
          return relative if RerunWorkspaceSupport::DEFAULT_TOP_LEVEL_NAMES.include?(parts.first)
          return relative if RerunWorkspaceSupport.top_level_support_bridge?(issue_workspace: issue_workspace, path: path)
          if path.directory? && path.join(".git").exist? && RerunWorkspaceSupport.checked_out_internal_parent_branch?(path)
            return relative
          end
          raise "path is not an allowed top-level quarantine target: #{path}"
        end
        return relative if parts.size == 2 && RerunWorkspaceSupport::DEFAULT_REPO_LOCAL_NAMES.include?(parts.last)

        raise "path is not an allowed rerun quarantine target: #{path}"
      rescue ArgumentError
        raise "path is outside issue workspace: #{path}"
      end

      def quarantine_paths(issue_workspace:, quarantine_root:, paths:)
        moved = []
        FileUtils.mkdir_p(quarantine_root)
        paths.each do |candidate|
          next unless candidate.exist? || candidate.symlink?

          relative = ensure_allowed_relative_path(issue_workspace: issue_workspace, path: candidate)
          destination = quarantine_root.join(relative)
          FileUtils.mkdir_p(destination.dirname)
          FileUtils.mv(candidate.to_s, destination.to_s)
          moved << QuarantinedPath.new(source: candidate.to_s, destination: destination.to_s)
        end
        moved
      end

      def quarantine_rerun_artifacts(root_dir:, project:, task_ref:, explicit_paths: [], now: Time.now.utc)
        issue_workspace = RerunWorkspaceSupport.compute_issue_workspace(root_dir: root_dir, project: project, task_ref: task_ref)
        quarantine_root = RerunWorkspaceSupport.compute_quarantine_root(root_dir: root_dir, project: project, task_ref: task_ref, now: now)
        paths =
          if explicit_paths.nil? || explicit_paths.empty?
            RerunWorkspaceSupport.collect_default_rerun_paths(issue_workspace: issue_workspace)
          else
            explicit_paths.map { |path| issue_workspace.join(path) }
          end
        moved = quarantine_paths(issue_workspace: issue_workspace, quarantine_root: quarantine_root, paths: paths)
        {
          "project" => project,
          "task_ref" => task_ref,
          "issue_workspace" => issue_workspace.to_s,
          "quarantine_root" => quarantine_root.to_s,
          "moved" => moved.map(&:to_h)
        }
      end

      def parse_args(argv)
        options = {
          path: []
        }
        parser = OptionParser.new
        parser.banner = "usage: rerun_quarantine.rb --project NAME --root-dir DIR --task-ref REF [options]"
        parser.on("--project VALUE") { |value| options[:project] = value }
        parser.on("--root-dir VALUE") { |value| options[:root_dir] = value }
        parser.on("--task-ref VALUE") { |value| options[:task_ref] = value }
        parser.on("--path VALUE") { |value| options[:path] << value }
        parser.parse!(argv)

        %i[project root_dir task_ref].each do |key|
          raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
        end
        options
      end

      def main(argv = ARGV, out: $stdout)
        options = parse_args(argv.dup)
        result = quarantine_rerun_artifacts(
          root_dir: options.fetch(:root_dir),
          project: options.fetch(:project),
          task_ref: options.fetch(:task_ref),
          explicit_paths: options.fetch(:path)
        )
        out.puts(JSON.pretty_generate(result))
        0
      rescue OptionParser::ParseError => e
        warn(e.message)
        1
      end
    end
  end
end

A3RerunQuarantine = A3::Operator::RerunQuarantine unless Object.const_defined?(:A3RerunQuarantine)
