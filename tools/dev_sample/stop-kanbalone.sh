#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
A2O_BUNDLE_KANBALONE_PORT="$A2O_DEV_SAMPLE_KANBALONE_PORT" \
A2O_BUNDLE_AGENT_PORT="$A2O_DEV_SAMPLE_AGENT_PORT" \
docker compose -p "$A2O_DEV_SAMPLE_COMPOSE_PROJECT" -f docker/compose/a2o-kanbalone.yml down
