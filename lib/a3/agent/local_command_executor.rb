# frozen_string_literal: true

require "open3"

module A3
  module Agent
    class LocalCommandExecutor
      Result = Struct.new(:status, :exit_code, :combined_log, keyword_init: true)

      def call(request)
        stdout, stderr, status, exit_code = capture(request)
        Result.new(
          status: status,
          exit_code: exit_code,
          combined_log: stdout.to_s + stderr.to_s
        )
      rescue Errno::ENOENT => e
        Result.new(status: :failed, exit_code: 127, combined_log: "#{e.class}: #{e.message}\n")
      rescue SystemCallError => e
        Result.new(status: :failed, exit_code: 1, combined_log: "#{e.class}: #{e.message}\n")
      end

      private

      def capture(request)
        stdout = +""
        stderr = +""
        status = nil
        exit_code = nil
        Open3.popen3(request.env, request.command, *request.args, chdir: request.working_dir) do |_stdin, out, err, wait_thread|
          deadline = Time.now + request.timeout_seconds
          readers = {out => stdout, err => stderr}
          until readers.empty?
            remaining = deadline - Time.now
            if remaining <= 0
              terminate(wait_thread.pid)
              return [stdout, stderr + "A2O agent command timed out after #{request.timeout_seconds}s\n", :timed_out, nil]
            end

            ready = IO.select(readers.keys, nil, nil, [remaining, 0.1].min)
            next unless ready

            ready.first.each do |io|
              chunk = io.read_nonblock(4096, exception: false)
              if chunk.nil?
                readers.delete(io)
              elsif chunk != :wait_readable
                readers.fetch(io) << chunk
              end
            end
          end
          process_status = wait_thread.value
          status = process_status.success? ? :succeeded : :failed
          exit_code = process_status.exitstatus
        end
        [stdout, stderr, status, exit_code]
      end

      def terminate(pid)
        Process.kill("TERM", pid)
        sleep 0.2
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

    end
  end
end
