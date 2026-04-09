# frozen_string_literal: true

module A3
  module Application
    class QuarantineTerminalTaskWorkspaces
      QuarantinedWorkspace = Struct.new(:task_ref, :quarantine_path, keyword_init: true)
      Result = Struct.new(:quarantined, keyword_init: true)

      def initialize(task_repository:, provisioner:)
        @task_repository = task_repository
        @provisioner = provisioner
      end

      def call
        quarantined = @task_repository.all
          .select { |task| terminal_status?(task) && task.current_run_ref.nil? }
          .map do |task|
            quarantine_path = @provisioner.quarantine_task(task_ref: task.ref)
            next unless quarantine_path

            QuarantinedWorkspace.new(task_ref: task.ref, quarantine_path: quarantine_path)
          end
          .compact

        Result.new(quarantined: quarantined.freeze)
      end

      private

      def terminal_status?(task)
        %i[done blocked].include?(task.status)
      end
    end
  end
end
