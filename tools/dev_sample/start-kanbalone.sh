#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
A2O_BUNDLE_KANBALONE_PORT="$A2O_DEV_SAMPLE_KANBALONE_PORT" \
A2O_BUNDLE_AGENT_PORT="$A2O_DEV_SAMPLE_AGENT_PORT" \
docker compose -p "$A2O_DEV_SAMPLE_COMPOSE_PROJECT" -f docker/compose/a2o-kanbalone.yml up -d kanbalone

ready=false
for _ in $(seq 1 40); do
  if python3 - "$A2O_DEV_SAMPLE_KANBAN_URL" <<'PY' >/dev/null 2>&1
import json
import sys
import urllib.request

health = json.load(urllib.request.urlopen(sys.argv[1].rstrip("/") + "/api/health", timeout=1))
raise SystemExit(0 if health.get("ok") else 1)
PY
  then
    ready=true
    break
  fi
  sleep 0.25
done

if [ "$ready" != "true" ]; then
  echo "dev_sample_kanbalone=not_ready url=$A2O_DEV_SAMPLE_KANBAN_URL" >&2
  exit 1
fi

echo "dev_sample_kanbalone_url=$A2O_DEV_SAMPLE_KANBAN_URL"
echo "dev_sample_compose_project=$A2O_DEV_SAMPLE_COMPOSE_PROJECT"
