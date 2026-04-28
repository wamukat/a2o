# frozen_string_literal: true

require_relative "../domain/task_phase_projection"
require_relative "../domain/runnable_task_assessment"
require_relative "../domain/scheduler_selection_policy"
require_relative "../domain/upstream_line_guard"
require "json"
require "time"

module A3
  module Application
    class ShowWatchSummary
      Summary = Struct.new(
        :scheduler_paused,
        :scheduler_paused_at,
        :next_candidates,
        :running_entries,
        :tasks,
        :warnings,
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
        :task_kind,
        :status,
        :parent_ref,
        :blocking_task_refs,
        :next_candidate,
        :running,
        :waiting,
        :done,
        :blocked,
        :blocked_lines,
        :running_entry,
        :phase_counts,
        :phase_states,
        :latest_phase,
        keyword_init: true
      )

      def initialize(task_repository:, run_repository:, scheduler_state_repository:, kanban_tasks: nil, kanban_snapshots_by_ref: {}, kanban_snapshots_by_id: {}, agent_jobs_by_task_ref: {}, upstream_line_guard: A3::Domain::UpstreamLineGuard.new, scheduler_selection_policy: A3::Domain::SchedulerSelectionPolicy.new, clock: -> { Time.now.utc })
        @task_repository = task_repository
        @run_repository = run_repository
        @scheduler_state_repository = scheduler_state_repository
        @kanban_tasks = kanban_tasks
        @kanban_snapshots_by_ref = kanban_snapshots_by_ref || {}
        @kanban_snapshots_by_id = kanban_snapshots_by_id || {}
        @agent_jobs_by_task_ref = agent_jobs_by_task_ref || {}
        @upstream_line_guard = upstream_line_guard
        @scheduler_selection_policy = scheduler_selection_policy
        @clock = clock
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
          tasks: sort_tasks_for_tree(task_entries).freeze,
          warnings: []
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
        kanban_snapshot = resolve_kanban_snapshot(task)
        blocked_lines = build_detail_lines(runtime_task, task_runs, assessment, upstream_assessment, kanban_snapshot: kanban_snapshot)
        waiting = waiting_assessment?(assessment) || !upstream_assessment.healthy?

        TaskEntry.new(
          ref: task.ref,
          title: display_title(runtime_task, kanban_snapshot: kanban_snapshot),
          task_kind: task.kind,
          status: display_status(canonical_status),
          parent_ref: task.parent_ref,
          blocking_task_refs: task.blocking_task_refs,
          next_candidate: task.ref == selected_next_ref,
          running: !running_entry.nil?,
          waiting: waiting,
          done: canonical_status == :done,
          blocked: %i[blocked needs_clarification].include?(canonical_status),
          blocked_lines: blocked_lines,
          running_entry: running_entry,
          phase_counts: phase_counts_for(task, task_runs),
          phase_states: phase_states_for(task, task_runs),
          latest_phase: latest_phase
        )
      end

      def select_next_ref(tasks:, runs:, assessments_by_ref:)
        runnable_assessments = tasks.filter_map do |task|
          assessment = assessments_by_ref.fetch(task.ref)
          next unless assessment.runnable?
          next unless @upstream_line_guard.evaluate(task: task, phase: assessment.phase, tasks: tasks, runs: runs).healthy?

          assessment
        end

        @scheduler_selection_policy
          .sort_assessments(assessments: runnable_assessments, tasks: tasks)
          .first
          &.task_ref
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
          blocked: "Blocked",
          needs_clarification: "Needs clarification"
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
          heartbeat_age_seconds: heartbeat_age_seconds_for(task.ref),
          detail: run.source_descriptor.ref
        )
      end

      def heartbeat_age_seconds_for(task_ref)
        record = @agent_jobs_by_task_ref[task_ref]
        return nil unless record.is_a?(Hash)

        heartbeat_at = parse_heartbeat_time(record["heartbeat_at"])
        return nil unless heartbeat_at

        age = (@clock.call - heartbeat_at).to_i
        age.negative? ? 0 : age
      end

      def parse_heartbeat_time(raw_value)
        value = raw_value.to_s.strip
        return nil if value.empty?

        Time.iso8601(value).utc
      rescue ArgumentError
        nil
      end

      def running_status?(status)
        %i[in_progress in_review verifying merging].include?(status)
      end

      def build_detail_lines(task, task_runs, assessment, upstream_assessment, kanban_snapshot: nil)
        lines = []
        latest_run = task_runs.last
        if task.verification_source_ref
          lines << "merge_recovery verification_source_ref=#{task.verification_source_ref}"
        end
        append_kanban_tag_reason_lines(lines, kanban_snapshot)
        append_review_disposition_lines(lines, task_runs)
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
        if latest_run
          append_clarification_request_lines(lines, latest_run)
          phase_record = latest_run.phase_records.reverse_each.find { |item| !item.blocked_diagnosis.nil? }
          diagnosis = phase_record&.blocked_diagnosis
          if diagnosis
            lines << "error_category=#{diagnosis.error_category}"
            lines << "remediation=#{diagnosis.remediation_summary}"
            append_validation_error_lines(lines, diagnosis.infra_diagnostics)
            lines.concat([diagnosis.diagnostic_summary || diagnosis.observed_state].compact.map(&:to_s).reject(&:empty?))
          end
        end
        lines.freeze
      end

      def append_kanban_tag_reason_lines(lines, kanban_snapshot)
        return unless kanban_snapshot.is_a?(Hash)

        Array(kanban_snapshot["label_reasons"]).each do |item|
          next unless item.is_a?(Hash)

          reason = single_line(item["reason"])
          next unless present?(reason)

          label = single_line(item["title"] || item["name"] || item.dig("tag", "title") || item.dig("tag", "name"))
          label_part = present?(label) ? " label=#{label}" : ""
          lines << "kanban_tag_reason#{label_part} reason=#{reason}"
          details = item["details"]
          lines << "kanban_tag_details#{label_part} #{JSON.generate(details)}" if details.is_a?(Hash) && !details.empty?
        end
      end

      def append_validation_error_lines(lines, diagnostics)
        return unless diagnostics.is_a?(Hash)

        Array(diagnostics["validation_errors"]).each do |error|
          next if error.to_s.strip.empty?

          lines << "validation_error=#{single_line(error)}"
        end
      end

      def append_clarification_request_lines(lines, run)
        phase_record = run.phase_records.reverse_each.find { |item| item.execution_record&.clarification_request.is_a?(Hash) }
        request = phase_record&.execution_record&.clarification_request
        return unless request.is_a?(Hash)

        lines << "clarification_question=#{single_line(request['question'])}" if present?(request["question"])
        lines << "clarification_context=#{single_line(request['context'])}" if present?(request["context"])
        options = Array(request["options"]).map { |option| single_line(option) }.reject(&:empty?)
        lines << "clarification_options=#{options.join(' | ')}" unless options.empty?
        lines << "clarification_impact=#{single_line(request['impact'])}" if present?(request["impact"])
      end

      def append_review_disposition_lines(lines, task_runs)
        disposition = latest_review_disposition(task_runs)
        return unless disposition

        fields = []
        fields << disposition["kind"] if present?(disposition["kind"])
        fields << "repo_scope=#{single_line(disposition['repo_scope'])}" if present?(disposition["repo_scope"])
        fields << "finding_key=#{single_line(disposition['finding_key'])}" if present?(disposition["finding_key"])
        lines << "review=#{fields.join(' ')}" unless fields.empty?
        lines << "review_summary=#{single_line(disposition['summary'])}" if present?(disposition["summary"])
      end

      def latest_review_disposition(task_runs)
        task_runs.reverse_each do |run|
          run.phase_records.reverse_each do |record|
            next unless %i[implementation review].include?(record.phase)

            disposition = record.execution_record&.review_disposition
            return disposition if disposition.is_a?(Hash)
          end
        end
        nil
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def single_line(text)
        text.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")
      end

      def waiting_assessment?(assessment)
        %i[blocked_by_tasks sibling_running parent_waiting_for_children upstream_unhealthy].include?(assessment.reason)
      end

      def phase_counts_for(task, task_runs)
        task_runs.each_with_object(Hash.new(0)) do |run, counts|
          phase = normalize_phase(canonical_phase_for(task, run.phase).to_s)
          counts[phase] += 1 if phase
        end
      end

      def phase_states_for(task, task_runs)
        task_runs.each_with_object({}) do |run, states|
          phase = normalize_phase(canonical_phase_for(task, run.phase).to_s)
          next unless phase

          outcome = run.terminal_outcome&.to_sym
          if phase == "review" && outcome == :rework
            states[phase] = :failed
          else
            states[phase] = :done
          end
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
        by_parent.each_value { |children| children.replace(topologically_sort_siblings(children)) }

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

      def topologically_sort_siblings(tasks)
        refs = tasks.map(&:ref)
        by_ref = tasks.each_with_object({}) { |task, memo| memo[task.ref] = task }
        dependents_by_ref = Hash.new { |hash, key| hash[key] = [] }
        dependency_count_by_ref = refs.each_with_object({}) { |ref, memo| memo[ref] = 0 }

        tasks.each do |task|
          sibling_blockers = task.blocking_task_refs.select { |ref| by_ref.key?(ref) }
          sibling_blockers.each do |blocker_ref|
            dependents_by_ref[blocker_ref] << task.ref
            dependency_count_by_ref[task.ref] += 1
          end
        end

        ready = refs.select { |ref| dependency_count_by_ref.fetch(ref).zero? }.sort_by { |ref| task_ref_sort_key(ref) }
        ordered_refs = []

        until ready.empty?
          ref = ready.shift
          ordered_refs << ref

          dependents_by_ref.fetch(ref, []).sort_by { |dependent_ref| task_ref_sort_key(dependent_ref) }.each do |dependent_ref|
            dependency_count_by_ref[dependent_ref] -= 1
            next unless dependency_count_by_ref.fetch(dependent_ref).zero?

            ready << dependent_ref
            ready.sort_by! { |candidate_ref| task_ref_sort_key(candidate_ref) }
          end
        end

        unresolved_refs = refs.reject { |ref| ordered_refs.include?(ref) }.sort_by { |ref| task_ref_sort_key(ref) }
        (ordered_refs + unresolved_refs).map { |ref| by_ref.fetch(ref) }
      end

      def task_ref_sort_key(ref)
        text = ref.to_s
        match = text.match(/#(\d+)\z/)
        numeric_id = match ? match[1].to_i : Float::INFINITY
        [text.sub(/#\d+\z/, "#"), numeric_id, text]
      end
    end
  end
end
