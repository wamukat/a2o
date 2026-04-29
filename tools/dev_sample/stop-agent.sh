#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

stop_pid_file() {
  pid_file="$1"
  label="$2"
  if [ ! -f "$pid_file" ]; then
    echo "$label=not_running"
    return
  fi

  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    echo "$label=stopped pid=$pid"
  else
    echo "$label=stale pid=$pid"
  fi
  rm -f "$pid_file"
}

stop_pid_file "$A2O_DEV_SAMPLE_STORAGE_DIR/agent-worker.pid" "dev_sample_agent_worker"
stop_pid_file "$A2O_DEV_SAMPLE_STORAGE_DIR/agent-server.pid" "dev_sample_agent_server"
