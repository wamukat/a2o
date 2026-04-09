# frozen_string_literal: true

require "json"
require "open3"

module A3
  module Infra
    class KanbanCliCommandClient
      def initialize(command_argv:, project:, working_dir: nil)
        @command_argv = Array(command_argv).map(&:to_s).freeze
        @project = project.to_s
        @working_dir = working_dir && File.expand_path(working_dir)
      end

      def run_json_command(*args)
        stdout, stderr, status = Open3.capture3(*@command_argv, *args, chdir: @working_dir)
        raise A3::Domain::ConfigurationError, build_command_error(stderr, status.exitstatus) unless status.success?

        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise A3::Domain::ConfigurationError, "kanban command did not return valid JSON: #{args.join(' ')} (#{e.message})"
      end

      def run_command(*args)
        _stdout, stderr, status = Open3.capture3(*@command_argv, *args, chdir: @working_dir)
        raise A3::Domain::ConfigurationError, build_command_error(stderr, status.exitstatus) unless status.success?

        nil
      end

      def fetch_task_by_id(task_id)
        payload = run_json_command("task-get", "--project", @project, "--task-id", Integer(task_id).to_s)
        raise A3::Domain::ConfigurationError, "kanban task-get must return an object" unless payload.is_a?(Hash)

        payload
      end

      def fetch_task_by_ref(task_ref)
        payload = run_json_command("task-get", "--project", @project, "--task", String(task_ref))
        raise A3::Domain::ConfigurationError, "kanban task-get must return an object" unless payload.is_a?(Hash)

        payload
      end

      def load_task_labels(task_id, include_project: false)
        args = ["task-label-list"]
        args += ["--project", @project] if include_project
        args += ["--task-id", Integer(task_id).to_s]
        payload = run_json_command(*args)
        raise A3::Domain::ConfigurationError, "kanban task-label-list must return an array" unless payload.is_a?(Array)

        payload
      end

      def resolve_task_id(task_ref, external_task_id:, canonical_required: true)
        return Integer(external_task_id) if external_task_id

        value = String(task_ref).strip
        canonical = /\A.+?#\d+\z/.match?(value)
        raise A3::Domain::ConfigurationError, "kanban task ref must be canonical Project#N: #{task_ref}" if canonical_required && !canonical
        return nil unless canonical

        Integer(fetch_task_by_ref(value).fetch("id"))
      rescue ArgumentError
        nil
      end

      private

      def build_command_error(stderr, exitstatus)
        detail = stderr.to_s.strip
        message = "kanban command failed (exit=#{exitstatus})"
        detail.empty? ? message : "#{message}: #{detail}"
      end
    end
  end
end
