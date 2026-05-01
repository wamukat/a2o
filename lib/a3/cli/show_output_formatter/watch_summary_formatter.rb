# frozen_string_literal: true

require "a3/version"

module A3
  module CLI
    module ShowOutputFormatter
      module WatchSummaryFormatter
        ANSI = {
          reset: "\e[0m",
          dim: "\e[2m",
          green: "\e[32m",
          yellow: "\e[33m",
          red: "\e[31m",
          cyan: "\e[36m"
        }.freeze
        TASK_SYMBOLS = {
          idle: "_",
          waiting: ".",
          next: "*",
          running: ">",
          done: "o",
          blocked: "!"
        }.freeze
        PHASE_SYMBOLS = {
          pending: ".",
          done: "o",
          failed: "x",
          running: ">",
          blocked: "!",
          not_applicable: "-"
        }.freeze
        BOX = {
          horizontal: "-",
          vertical: "|",
          corner: "+"
        }.freeze
        PHASE_ORDER = %w[implementation review inspection merge].freeze
        TREE_REF_MIN_WIDTH = 9
        TREE_TITLE_WIDTH = 59
        HEADER_LEGEND_WIDTH = 43
        PHASE_HEADER_DASH_COUNTS = {
          "implementation" => 5,
          "review" => 7,
          "inspection" => 9,
          "merge" => 11
        }.freeze
        PHASE_HEADER_OFFSET = 0

        module_function

        def lines(summary, details: false)
          [
            render_scheduler_state(summary),
            render_warnings_section(summary),
            render_decomposition_section(summary),
            render_task_tree(summary, details: details),
            render_next_section(summary),
            render_running_section(summary)
          ].reject(&:empty?).flat_map.with_index do |section, index|
            rendered = decorate_lines(section.split("\n"))
            index.zero? ? rendered : ["", *rendered]
          end
        end

        def render_warnings_section(summary)
          warnings = Array(summary.respond_to?(:warnings) ? summary.warnings : [])
          return "" if warnings.empty?

          (["Warnings"] + warnings.map { |warning| "- #{single_line(warning)}" }).join("\n")
        end

        def render_scheduler_state(summary)
          version_suffix = " version=#{A3::VERSION}"
          if summary.scheduler_paused && summary.scheduler_paused_at
            "Scheduler: paused (paused_at=#{summary.scheduler_paused_at})#{version_suffix}"
          elsif summary.scheduler_paused
            "Scheduler: paused#{version_suffix}"
          elsif summary.running_entries.any? || active_decomposition_entries(summary).any?
            "Scheduler: running#{version_suffix}"
          else
            "Scheduler: idle#{version_suffix}"
          end
        end

        def render_task_tree(summary, details: false)
          depth_by_ref = build_depths(summary.tasks)
          tree_ref_width = [TREE_REF_MIN_WIDTH, *summary.tasks.map { |task| display_width(tree_ref_label(task.ref, depth_by_ref[task.ref])) }].max
          lines = task_tree_header(tree_ref_width)
          if summary.tasks.empty?
            lines << "  (no tasks to watch)"
            return lines.join("\n")
          end

          summary.tasks.each do |task|
            lines << "#{task_badge(task)} #{pad_right(tree_ref_label(task.ref, depth_by_ref[task.ref]), tree_ref_width)} #{pad_right(truncate(task.title, TREE_TITLE_WIDTH), TREE_TITLE_WIDTH)} #{task_phase_bar(task)}"
            if details
              task.blocked_lines.each do |line|
                lines << "#{' ' * (4 + tree_ref_width + 1)}#{truncate(single_line(line), TREE_TITLE_WIDTH + 24)}"
              end
            end
          end
          lines.join("\n")
        end

        def render_decomposition_section(summary)
          entries = decomposition_entries(summary)
          return "" if entries.empty?

          lines = ["Decomposition"]
          entries.each do |entry|
            parts = ["- #{short_ref(entry.task_ref)}", "state=#{entry.state}"]
            parts << "stage=#{entry.stage}" if entry.respond_to?(:stage) && entry.stage
            parts << "disposition=#{entry.disposition}" if entry.disposition
            parts << "fingerprint=#{entry.proposal_fingerprint}" if entry.proposal_fingerprint
            lines << parts.join(" ")
            lines << "  blocked_reason=#{single_line(entry.blocked_reason)}" if entry.blocked_reason && entry.state == "blocked"
          end
          lines.join("\n")
        end

        def decomposition_entries(summary)
          Array(summary.respond_to?(:decomposition_entries) ? summary.decomposition_entries : [])
        end

        def active_decomposition_entries(summary)
          decomposition_entries(summary).select { |entry| entry.respond_to?(:running) && entry.running }
        end

        def render_next_section(summary)
          return "" if summary.next_candidates.empty?

          (["Next"] + summary.next_candidates.map { |ref| "- #{short_ref(ref)}" }).join("\n")
        end

        def render_running_section(summary)
          return "" if summary.running_entries.empty?

          lines = ["Running"]
          summary.running_entries.each do |entry|
            heartbeat = entry.heartbeat_age_seconds.nil? ? "?" : "#{entry.heartbeat_age_seconds}s"
            lines << "- #{short_ref(entry.task_ref)} #{entry.phase}/#{entry.internal_phase}/#{entry.state} hb=#{heartbeat}"
            lines << "  detail: #{entry.detail}" if entry.detail
          end
          lines.join("\n")
        end

        def task_tree_header(tree_ref_width)
          bar_start = 4 + tree_ref_width + 1 + TREE_TITLE_WIDTH + 1 + PHASE_HEADER_OFFSET
          phase_rows = task_tree_phase_header(bar_start)
          width = phase_rows.map { |row| display_width(row) }.max
          task_legend_rows = [
            "[#{TASK_SYMBOLS.fetch(:idle)}] idle     [#{TASK_SYMBOLS.fetch(:waiting)}] waiting  |  #{PHASE_SYMBOLS.fetch(:pending)} : none     |",
            "[#{TASK_SYMBOLS.fetch(:next)}] next     [#{TASK_SYMBOLS.fetch(:running)}] running  |  #{PHASE_SYMBOLS.fetch(:running)} : running  |",
            "[#{TASK_SYMBOLS.fetch(:done)}] done     [#{TASK_SYMBOLS.fetch(:blocked)}] blocked  |  #{PHASE_SYMBOLS.fetch(:done)} : done     |",
            "#{' ' * 26}|  #{PHASE_SYMBOLS.fetch(:failed)} : failed   #{PHASE_SYMBOLS.fetch(:blocked)} : blocked |"
          ]
          lines = ["Task Tree"]
          phase_rows.each_with_index do |phase_row, index|
            row = phase_row
            row = overlay_text(row, pad_right(task_legend_rows[index], HEADER_LEGEND_WIDTH), target_display_start: 0) if index < task_legend_rows.length
            lines << pad_right(row, width).rstrip
          end
          lines
        end

        def task_tree_phase_header(bar_start)
          labels = [
            ["Implementation", 0],
            ["Review", 2],
            ["Inspecting", 4],
            ["Merging", 6]
          ]
          width = bar_start + display_width(phase_bar_slots)
          phase_columns = PHASE_ORDER.each_index.map { |index| bar_start + (index * 2) }.freeze
          lines = []

          (labels.length - 1).downto(0) do |index|
            label, offset = labels[index]
            target = phase_columns.fetch(index)
            dash_count = PHASE_HEADER_DASH_COUNTS.fetch(PHASE_ORDER.fetch(index))
            row = " " * width
            start = target - (display_width(label) + 1 + dash_count)
            row = overlay_text(row, label, target_display_start: start)
            row = overlay_text(row, " ", target_display_start: start + display_width(label))
            row = overlay_text(row, BOX.fetch(:horizontal) * dash_count, target_display_start: start + display_width(label) + 1)
            row = overlay_text(row, BOX.fetch(:corner), target_display_start: target)
            phase_columns[(index + 1)..].to_a.each do |column|
              row = overlay_text(row, BOX.fetch(:vertical), target_display_start: column)
            end
            lines << row.rstrip
          end

          row = " " * width
          phase_columns.each do |column|
            row = overlay_text(row, BOX.fetch(:vertical), target_display_start: column)
          end
          lines << row.rstrip
          lines
        end

        def task_symbol(task)
          return TASK_SYMBOLS.fetch(:blocked) if task.blocked
          return TASK_SYMBOLS.fetch(:running) if task.running
          return TASK_SYMBOLS.fetch(:next) if task.next_candidate
          return TASK_SYMBOLS.fetch(:waiting) if task.waiting
          return TASK_SYMBOLS.fetch(:done) if task.done

          TASK_SYMBOLS.fetch(:idle)
        end

        def task_badge(task)
          "[#{task_symbol(task)}]"
        end

        def task_phase_bar(task)
          latest_phase = task.latest_phase
          PHASE_ORDER.map do |phase|
            if task.task_kind == :parent && phase == "implementation"
              PHASE_SYMBOLS.fetch(:not_applicable)
            elsif task.running && latest_phase == phase
              PHASE_SYMBOLS.fetch(:running)
            elsif task.blocked && latest_phase == phase
              PHASE_SYMBOLS.fetch(:blocked)
            elsif task_phase_state(task, phase) == :failed
              PHASE_SYMBOLS.fetch(:failed)
            elsif task.phase_counts.fetch(phase, 0).positive?
              PHASE_SYMBOLS.fetch(:done)
            elsif latest_phase && PHASE_ORDER.index(latest_phase) && PHASE_ORDER.index(latest_phase) > PHASE_ORDER.index(phase)
              PHASE_SYMBOLS.fetch(:done)
            else
              PHASE_SYMBOLS.fetch(:pending)
            end
          end.join("/")
        end

        def task_phase_state(task, phase)
          return nil unless task.respond_to?(:phase_states)

          states = task.phase_states || {}
          states[phase] || states[phase.to_sym]
        end

        def build_depths(tasks)
          parent_by_ref = tasks.each_with_object({}) { |task, memo| memo[task.ref] = task.parent_ref }
          tasks.each_with_object({}) do |task, memo|
            depth = 0
            current = task.parent_ref
            while current && parent_by_ref.key?(current)
              depth += 1
              current = parent_by_ref[current]
            end
            memo[task.ref] = depth
          end
        end

        def tree_ref_label(task_ref, depth)
          "#{'  ' * depth}#{short_ref(task_ref)}"
        end

        def short_ref(task_ref)
          task_ref.include?("#") ? "##{task_ref.split('#', 2).last}" : task_ref
        end

        def single_line(text)
          text.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")
        end

        def truncate(text, width)
          return text if display_width(text) <= width

          slice_display_width(text, width - 3) + "..."
        end

        def pad_right(text, width)
          text + (" " * [0, width - display_width(text)].max)
        end

        def display_width(text)
          text.to_s.each_char.sum do |char|
            east_asian?(char) ? 2 : 1
          end
        end

        def slice_display_width(text, width)
          used = 0
          text.each_char.each_with_object(+"") do |char, result|
            width_for_char = east_asian?(char) ? 2 : 1
            break result if used + width_for_char > width

            result << char
            used += width_for_char
          end
        end

        def overlay_text(base, overlay, target_display_start:)
          prefix = slice_display_width(base, target_display_start)
          used_width = display_width(prefix)
          prefix = pad_right(prefix, target_display_start) if used_width < target_display_start
          remaining = suffix_from_display_width(base, target_display_start + display_width(overlay))
          prefix + overlay + remaining
        end

        def suffix_from_display_width(text, start_width)
          used = 0
          started = false
          text.each_char.each_with_object(+"") do |char, result|
            width_for_char = east_asian?(char) ? 2 : 1
            started = true if used >= start_width
            result << char if started
            used += width_for_char
            started = true if used == start_width && result.empty?
          end
        end

        def east_asian?(char)
          char && char.unpack1("U") > 0x7f
        end

        def phase_bar_slots
          ([PHASE_SYMBOLS.fetch(:pending)] * PHASE_ORDER.length).join("/")
        end

        def decorate_lines(lines)
          return lines if lines.empty?

          [colorize(lines.first, :cyan)] + lines.drop(1).map { |line| decorate_line(line) }
        end

        def decorate_line(line)
          symbol = task_row_symbol(line)
          if symbol == TASK_SYMBOLS.fetch(:blocked)
            colorize(line, :red)
          elsif symbol == TASK_SYMBOLS.fetch(:running)
            colorize(line, :yellow)
          elsif symbol == TASK_SYMBOLS.fetch(:next)
            colorize(line, :cyan)
          elsif symbol == TASK_SYMBOLS.fetch(:waiting)
            line
          elsif symbol == TASK_SYMBOLS.fetch(:done)
            colorize(line, :green)
          elsif line.start_with?("- #")
            colorize(line, :cyan)
          else
            line
          end
        end

        def colorize(text, color)
          "#{ANSI.fetch(color)}#{text}#{ANSI.fetch(:reset)}"
        end

        def task_tree_row?(line)
          !task_row_symbol(line).nil?
        end

        def task_row_symbol(line)
          match = line.match(/^\s*\[([#{Regexp.escape(TASK_SYMBOLS.values.join)}])\]\s+\#\d+/)
          match && match[1]
        end
      end
    end
  end
end
