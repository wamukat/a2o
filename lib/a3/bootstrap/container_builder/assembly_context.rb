# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class AssemblyContext
        def initialize(repositories:, runtime_services:)
          @repositories = repositories
          @runtime_services = runtime_services
        end

        def task_repository
          @repositories.fetch(:task_repository)
        end

        def storage_dir
          @repositories.fetch(:storage_dir)
        end

        def run_repository
          @repositories.fetch(:run_repository)
        end

        def scheduler_state_repository
          @repositories.fetch(:scheduler_state_repository)
        end

        def scheduler_cycle_repository
          @repositories.fetch(:scheduler_cycle_repository)
        end

        def build_scope_snapshot
          @runtime_services.fetch(:build_scope_snapshot)
        end

        def build_artifact_owner
          @runtime_services.fetch(:build_artifact_owner)
        end

        def plan_rerun
          @runtime_services.fetch(:plan_rerun)
        end


        def prepare_workspace
          @runtime_services.fetch(:prepare_workspace)
        end

        def plan_next_runnable_task
          @runtime_services.fetch(:plan_next_runnable_task)
        end

        def plan_next_decomposition_task
          @runtime_services.fetch(:plan_next_decomposition_task)
        end

        def schedule_next_run
          @runtime_services.fetch(:schedule_next_run)
        end

        def build_merge_plan
          @runtime_services.fetch(:build_merge_plan)
        end

        def run_verification
          @runtime_services.fetch(:run_verification)
        end

        def run_worker_phase
          @runtime_services.fetch(:run_worker_phase)
        end

        def run_merge
          @runtime_services.fetch(:run_merge)
        end

        def register_completed_run
          @runtime_services.fetch(:register_completed_run)
        end

        def reconcile_manual_merge_recovery
          @runtime_services.fetch(:reconcile_manual_merge_recovery)
        end

        def start_run
          @runtime_services.fetch(:start_run)
        end

        def scheduler_cycle_journal
          @scheduler_cycle_journal ||= @runtime_services[:scheduler_cycle_journal] || A3::Application::SchedulerCycleJournal.new(
            scheduler_state_repository: scheduler_state_repository,
            scheduler_cycle_repository: scheduler_cycle_repository
          )
        end

        def workspace_provisioner
          @runtime_services.fetch(:workspace_provisioner)
        end
      end
    end
  end
end
