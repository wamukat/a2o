# frozen_string_literal: true

require_relative "../domain/task_phase_projection"
require_relative "../domain/runnable_task_assessment"
require_relative "../domain/upstream_line_guard"

module A3
  module Application
    class ShowWatchSummary
      Summary = Struct.new(
        :scheduler_paused,
        :scheduler_paused_at,
        :next_candidates,
        :running_entries,
        :tasks,
        keyword_init: true
      )

      RunningEntry = Struct.new(
        :task_ref,
        :phase,
        :internal_phase,
        :state,
        :heartbeat_age_seconds,
        :detail,
        keyword_init: true
      )

      TaskEntry = Struct.new(
        :ref,
        :title,
        :status,
        :parent_ref,
        :next_candidate,
        :running,
        :waiting,
        :done,
        :blocked,
        :blocked_lines,
        :running_entry,
        :phase_counts,
        :latest_phase,
        keyword_init: true
      )

      def initialize(task_repository:, run_repository:, scheduler_state_repository:, kanban_tasks: nil, kanban_snapshots_by_ref: {}, kanban_snapshots_by_id: {}, upstream_line_guard: A3::Domain::UpstreamLineGuard.new)
        @task_repository = task_repository
        @run_repository = run_repository
        @scheduler_state_repository = scheduler_state_repository
        @kanban_tasks = kanban_tasks
        @kanban_snapshots_by_ref = kanban_snapshots_by_ref || {}
        @kanban_snapshots_by_id = kanban_snapshots_by_id || {}
        @upstream_line_guard = upstream_line_guard
      end

      def call
        runtime_tasks = @task_repository.all
        tasks = @kanban_tasks || runtime_tasks
        runs = @run_repository.all
        runs_by_task = runs.group_by(&:task_ref)
        runtime_tasks_by_ref = runtime_tasks.each_with_object({}) { |task, memo| memo[task.ref] = task }
        assessments_by_ref = tasks.each_with_object({}) do |task, memo|
          memo[task.ref] = A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks)
        end
        selected_next_ref = select_next_ref(tasks: tasks, runs: runs, assessments_by_ref: assessments_by_ref)
        state = @scheduler_state_repository.fetch

        task_entries = tasks.each_with_object([]) do |task, entries|
          entries << build_task_entry(
            task,
            runtime_task: runtime_tasks_by_ref[task.ref] || task,
            runs_by_task: runs_by_task,
            assessment: assessments_by_ref.fetch(task.ref),
            tasks: tasks,
            runs: runs,
            selected_next_ref: selected_next_ref
          )
        end

        Summary.new(
          scheduler_paused: state.paused,
          scheduler_paused_at: nil,
          next_candidates: selected_next_ref ? [selected_next_ref].freeze : [].freeze,
          running_entries: task_entries.map(&:running_entry).compact.sort_by(&:task_ref).freeze,
          tasks: sort_tasks_for_tree(task_entries).freeze
        )
      end

      private

      def build_task_entry(task, runtime_task:, runs_by_task:, assessment:, tasks:, runs:, selected_next_ref:)
        task_runs = runs_by_task.fetch(task.ref, [])
        current_run = runtime_task.current_run_ref && task_runs.find { |candidate| candidate.ref == runtime_task.current_run_ref }
        latest_run = task_runs.last
        canonical_status = canonical_status_for(runtime_task)
        latest_phase = resolve_latest_phase(task: runtime_task, current_run: current_run, latest_run: latest_run)
        running_entry = build_running_entry(runtime_task, run: current_run)
        runnable_phase = task.runnable_phase
        upstream_assessment = @upstream_line_guard.evaluate(task: task, phase: runnable_phase, tasks: tasks, runs: runs)
        blocked_lines = build_detail_lines(runtime_task, latest_run, assessment, upstream_assessment)
        kanban_snapshot = resolve_kanban_snapshot(task)
        waiting = waiting_assessment?(assessment) || !upstream_assessment.healthy?

        TaskEntry.new(
          ref: task.ref,
          title: display_title(runtime_task, kanban_snapshot: kanban_snapshot),
          status: display_status(canonical_status),
          parent_ref: task.parent_ref,
          next_candidate: task.ref == selected_next_ref,
          running: !running_entry.nil?,
          waiting: waiting,
          done: canonical_status == :done,
          blocked: canonical_status == :blocked,
          blocked_lines: blocked_lines,
          running_entry: running_entry,
          phase_counts: phase_counts_for(task, task_runs),
          latest_phase: latest_phase
        )
      end

      def select_next_ref(tasks:, runs:, assessments_by_ref:)
        tasks
          .filter_map do |task|
            assessment = assessments_by_ref.fetch(task.ref)
            next unless assessment.runnable?
            next unless @upstream_line_guard.evaluate(task: task, phase: assessment.phase, tasks: tasks, runs: runs).healthy?

            task.ref
          end
          .sort_by do |ref|
            task = tasks.find { |candidate| candidate.ref == ref }
            [-task.priority, task.ref]
          end
          .first
      end

      def display_title(task, kanban_snapshot:)
        return task.ref unless kanban_snapshot.is_a?(Hash)

        title = String(kanban_snapshot["title"]).strip
        title = task.ref if title.empty?
        kanban_status = String(kanban_snapshot["status"]).strip
        internal_status = display_status(task.status.to_sym)
        return title if kanban_status.empty? || kanban_status == internal_status

        "#{title} [kanban=#{kanban_status} internal=#{internal_status}]"
      end

      def resolve_kanban_snapshot(task)
        @kanban_snapshots_by_id[task.external_task_id] || @kanban_snapshots_by_ref[task.ref]
      end

      def display_status(status)
        {
          todo: "To do",
          in_progress: "In progress",
          in_review: "In review",
          verifying: "Inspection",
          merging: "Merging",
          done: "Done",
          blocked: "Blocked"
        }.fetch(status, status.to_s)
      end

      def build_running_entry(task, run:)
        return nil unless running_status?(canonical_status_for(task))
        return nil unless run

        phase = canonical_phase_for(task, run.phase).to_s
        RunningEntry.new(
          task_ref: task.ref,
          phase: phase,
          internal_phase: phase,
          state: "running_command",
          heartbeat_age_seconds: nil,
          detail: run.source_descriptor.ref
        )
      end

      def running_status?(status)
        %i[in_progress in_review verifying merging].include?(status)
      end

      def build_detail_lines(task, run, assessment, upstream_assessment)
        lines = []
        if task.verification_source_ref
          lines << "merge_recovery verification_source_ref=#{task.verification_source_ref}"
        end
        unless upstream_assessment.healthy?
          lines << "waiting_reason=#{upstream_assessment.reason}"
          unless upstream_assessment.blocking_task_refs.empty?
            lines << "waiting_on=#{upstream_assessment.blocking_task_refs.join(',')}"
          end
        end
        if waiting_assessment?(assessment)
          lines << "waiting_reason=#{assessment.reason}"
          unless assessment.blocking_task_refs.empty?
            lines << "waiting_on=#{assessment.blocking_task_refs.join(',')}"
          end
        end
        if run
          phase_record = run.phase_records.reverse_each.find { |item| !item.blocked_diagnosis.nil? }
          diagnosis = phase_record&.blocked_diagnosis
          if diagnosis
            lines << "error_category=#{diagnosis.error_category}"
            lines << "remediation=#{diagnosis.remediation_summary}"
            lines.concat([diagnosis.diagnostic_summary || diagnosis.observed_state].compact.map(&:to_s).reject(&:empty?))
          end
        end
        lines.freeze
      end

      def waiting_assessment?(assessment)
        %i[sibling_running parent_waiting_for_children upstream_unhealthy].include?(assessment.reason)
      end

      def phase_counts_for(task, task_runs)
        task_runs.each_with_object(Hash.new(0)) do |run, counts|
          phase = normalize_phase(canonical_phase_for(task, run.phase).to_s)
          counts[phase] += 1 if phase
        end
      end

      def resolve_latest_phase(task:, current_run:, latest_run:)
        [current_run, latest_run].compact.reverse_each do |run|
          normalized = normalize_phase(canonical_phase_for(task, run.phase).to_s)
          return normalized if normalized
        end
        fallback_phase = task.runnable_phase
        return nil unless fallback_phase

        normalize_phase(canonical_phase_for(task, fallback_phase).to_s)
      end

      def canonical_status_for(task)
        A3::Domain::TaskPhaseProjection.status_for(task_kind: task.kind, status: task.status)
      end

      def canonical_phase_for(task, phase)
        A3::Domain::TaskPhaseProjection.phase_for(task_kind: task.kind, phase: phase)
      end

      def normalize_phase(value)
        {
          "implementation" => "implementation",
          "review" => "review",
          "verification" => "inspection",
          "verifying" => "inspection",
          "merge" => "merge",
          "merging" => "merge"
        }[value]
      end

      def sort_tasks_for_tree(tasks)
        by_parent = Hash.new { |hash, key| hash[key] = [] }
        tasks.each { |task| by_parent[task.parent_ref] << task }
        by_parent.each_value { |children| children.sort_by! { |task| task.ref } }

        ordered = []
        visit = lambda do |parent_ref|
          by_parent[parent_ref].each do |task|
            ordered << task
            visit.call(task.ref)
          end
        end
        visit.call(nil)
        missing = tasks.reject { |task| ordered.include?(task) }.sort_by(&:ref)
        ordered.concat(missing)
        ordered
      end
    end
  end
end
