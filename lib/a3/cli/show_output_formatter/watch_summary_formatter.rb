# frozen_string_literal: true

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
          idle: "○",
          waiting: "…",
          next: "▷",
          running: "▶",
          done: "✔",
          blocked: "✖"
        }.freeze
        PHASE_SYMBOLS = {
          pending: "·",
          done: "✔",
          running: "▶",
          blocked: "✖"
        }.freeze
        DISPLAY_WIDTH_OVERRIDES = {
          "○" => 1,
          "…" => 1,
          "▷" => 1,
          "▶" => 1,
          "✔" => 1,
          "✖" => 1,
          "·" => 1,
          "─" => 1,
          "│" => 1,
          "┬" => 1,
          "┐" => 1,
          "┤" => 1,
          "├" => 1,
          "└" => 1,
          "┘" => 1,
          "┼" => 1
        }.freeze
        PHASE_ORDER = %w[implementation review inspection merge].freeze
        TREE_REF_MIN_WIDTH = 10
        TREE_TITLE_WIDTH = 64
        HEADER_LEGEND_WIDTH = 43
        PHASE_HEADER_DASH_COUNT = 5
        PHASE_HEADER_OFFSET = -2

        module_function

        def lines(summary)
          [
            render_scheduler_state(summary),
            render_task_tree(summary),
            render_next_section(summary),
            render_running_section(summary)
          ].reject(&:empty?).flat_map.with_index do |section, index|
            rendered = decorate_lines(section.split("\n"))
            index.zero? ? rendered : ["", *rendered]
          end
        end

        def render_scheduler_state(summary)
          if summary.scheduler_paused && summary.scheduler_paused_at
            "Scheduler: paused (paused_at=#{summary.scheduler_paused_at})"
          elsif summary.scheduler_paused
            "Scheduler: paused"
          elsif summary.running_entries.any?
            "Scheduler: running"
          else
            "Scheduler: idle"
          end
        end

        def render_task_tree(summary)
          depth_by_ref = build_depths(summary.tasks)
          tree_ref_width = [TREE_REF_MIN_WIDTH, *summary.tasks.map { |task| display_width(tree_ref_label(task.ref, depth_by_ref[task.ref])) }].max
          lines = task_tree_header(tree_ref_width)
          if summary.tasks.empty?
            lines << "  (no tasks to watch)"
            return lines.join("\n")
          end

          summary.tasks.each do |task|
            lines << "#{task_symbol(task)} #{pad_right(tree_ref_label(task.ref, depth_by_ref[task.ref]), tree_ref_width)} #{pad_right(truncate(task.title, TREE_TITLE_WIDTH), TREE_TITLE_WIDTH)} #{task_phase_bar(task)}"
            task.blocked_lines.each do |line|
              lines << "#{' ' * (4 + tree_ref_width + 1)}#{truncate(single_line(line), TREE_TITLE_WIDTH + 24)}"
            end
          end
          lines.join("\n")
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
            " #{TASK_SYMBOLS.fetch(:idle)} idle     #{TASK_SYMBOLS.fetch(:waiting)} waiting   │  #{PHASE_SYMBOLS.fetch(:pending)} none      │",
            " #{TASK_SYMBOLS.fetch(:next)} next     #{TASK_SYMBOLS.fetch(:running)} running   │  #{PHASE_SYMBOLS.fetch(:running)} running   │",
            " #{TASK_SYMBOLS.fetch(:done)} automation done      │  #{PHASE_SYMBOLS.fetch(:done)} phase done│",
            " #{TASK_SYMBOLS.fetch(:blocked)} blocked              │  #{PHASE_SYMBOLS.fetch(:blocked)} blocked   │"
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
            row = " " * width
            start = target - (display_width(label) + 1 + PHASE_HEADER_DASH_COUNT)
            row = overlay_text(row, label, target_display_start: start)
            row = overlay_text(row, " ", target_display_start: start + display_width(label))
            row = overlay_text(row, "─" * PHASE_HEADER_DASH_COUNT, target_display_start: start + display_width(label) + 1)
            row = overlay_text(row, "┐", target_display_start: target)
            phase_columns[(index + 1)..].to_a.each do |column|
              row = overlay_text(row, "│", target_display_start: column)
            end
            lines << row.rstrip
          end

          row = " " * width
          phase_columns.each do |column|
            row = overlay_text(row, "│", target_display_start: column)
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

        def task_phase_bar(task)
          latest_phase = task.latest_phase
          PHASE_ORDER.map do |phase|
            if task.running && latest_phase == phase
              PHASE_SYMBOLS.fetch(:running)
            elsif task.blocked && latest_phase == phase
              PHASE_SYMBOLS.fetch(:blocked)
            elsif task.phase_counts.fetch(phase, 0).positive?
              PHASE_SYMBOLS.fetch(:done)
            elsif latest_phase && PHASE_ORDER.index(latest_phase) && PHASE_ORDER.index(latest_phase) > PHASE_ORDER.index(phase)
              PHASE_SYMBOLS.fetch(:done)
            else
              PHASE_SYMBOLS.fetch(:pending)
            end
          end.join("/")
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
            DISPLAY_WIDTH_OVERRIDES.fetch(char) { east_asian?(char) ? 2 : 1 }
          end
        end

        def slice_display_width(text, width)
          used = 0
          text.each_char.each_with_object(+"") do |char, result|
            char_width = DISPLAY_WIDTH_OVERRIDES.fetch(char) { east_asian?(char) ? 2 : 1 }
            break result if used + char_width > width

            result << char
            used += char_width
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
            char_width = DISPLAY_WIDTH_OVERRIDES.fetch(char) { east_asian?(char) ? 2 : 1 }
            started = true if used >= start_width
            result << char if started
            used += char_width
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
          if task_tree_row?(line) && line.lstrip.start_with?(TASK_SYMBOLS.fetch(:blocked))
            colorize(line, :red)
          elsif task_tree_row?(line) && line.lstrip.start_with?(TASK_SYMBOLS.fetch(:running))
            colorize(line, :yellow)
          elsif task_tree_row?(line) && line.lstrip.start_with?(TASK_SYMBOLS.fetch(:next))
            colorize(line, :cyan)
          elsif task_tree_row?(line) && line.lstrip.start_with?(TASK_SYMBOLS.fetch(:waiting))
            colorize(line, :dim)
          elsif task_tree_row?(line) && line.lstrip.start_with?(TASK_SYMBOLS.fetch(:done))
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
          line.match?(/^\s*[#{Regexp.escape(TASK_SYMBOLS.values.join)}]\s+\#\d+/)
        end
      end
    end
  end
end
