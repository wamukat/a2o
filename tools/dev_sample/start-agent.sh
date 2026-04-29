#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
mkdir -p "$A2O_DEV_SAMPLE_STORAGE_DIR" "$A2O_DEV_SAMPLE_AGENT_WORKSPACE_DIR"

server_pid="$A2O_DEV_SAMPLE_STORAGE_DIR/agent-server.pid"
server_log="$A2O_DEV_SAMPLE_STORAGE_DIR/agent-server.log"
worker_pid="$A2O_DEV_SAMPLE_STORAGE_DIR/agent-worker.pid"
worker_log="$A2O_DEV_SAMPLE_STORAGE_DIR/agent-worker.log"

if [ -f "$server_pid" ] && kill -0 "$(cat "$server_pid")" 2>/dev/null; then
  echo "dev_sample_agent_server=already_running pid=$(cat "$server_pid") url=$A2O_DEV_SAMPLE_AGENT_URL"
else
  ruby - "$server_pid" "$server_log" "$A2O_DEV_SAMPLE_STORAGE_DIR" "$A2O_DEV_SAMPLE_AGENT_PORT" <<'RUBY'
pid_file, log_file, storage_dir, port = ARGV
pid = Process.spawn(
  "ruby", "-Ilib", "bin/a3", "agent-server",
  "--storage-dir", storage_dir,
  "--host", "127.0.0.1",
  "--port", port,
  pgroup: true,
  in: File::NULL,
  out: log_file,
  err: [:child, :out]
)
Process.detach(pid)
File.write(pid_file, pid.to_s)
RUBY
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if nc -z 127.0.0.1 "$A2O_DEV_SAMPLE_AGENT_PORT" 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! nc -z 127.0.0.1 "$A2O_DEV_SAMPLE_AGENT_PORT" 2>/dev/null; then
  echo "dev_sample_agent_server=failed log=$server_log" >&2
  exit 1
fi

if [ -f "$worker_pid" ] && kill -0 "$(cat "$worker_pid")" 2>/dev/null; then
  echo "dev_sample_agent_worker=already_running pid=$(cat "$worker_pid")"
else
  ruby - "$worker_pid" "$worker_log" "$A2O_DEV_SAMPLE_AGENT_URL" "$A2O_DEV_SAMPLE_AGENT_WORKSPACE_DIR" "$A2O_DEV_SAMPLE_ROOT" <<'RUBY'
pid_file, log_file, agent_url, workspace_dir, sample_root = ARGV
pid = Process.spawn(
  "go", "run", "./cmd/a3-agent",
  "--loop",
  "--poll-interval", "1s",
  "--control-plane-url", agent_url,
  "--workspace-root", workspace_dir,
  "--source-alias", "app=#{sample_root}",
  chdir: "agent-go",
  pgroup: true,
  in: File::NULL,
  out: log_file,
  err: [:child, :out]
)
Process.detach(pid)
File.write(pid_file, pid.to_s)
RUBY
fi

sleep 2
if ! kill -0 "$(cat "$worker_pid")" 2>/dev/null; then
  echo "dev_sample_agent_worker=failed log=$worker_log" >&2
  exit 1
fi

echo "dev_sample_agent_url=$A2O_DEV_SAMPLE_AGENT_URL"
echo "dev_sample_agent_server_log=$server_log"
echo "dev_sample_agent_worker_log=$worker_log"
