#!/usr/bin/env sh
set -eu

. "$(dirname "$0")/env.sh"

cd "$A2O_DEV_SAMPLE_ROOT"
storage_root="$(dirname "$A2O_DEV_SAMPLE_STORAGE_DIR")"
expected_storage_root="$A2O_DEV_SAMPLE_ROOT/.work/a2o-dev-sample"
if [ "$storage_root" != "$expected_storage_root" ]; then
  echo "refusing to reset unexpected dev sample storage root: $storage_root expected=$expected_storage_root" >&2
  exit 1
fi

if [ -x tools/dev_sample/stop-agent.sh ]; then
  tools/dev_sample/stop-agent.sh
fi

A2O_BUNDLE_KANBALONE_PORT="$A2O_DEV_SAMPLE_KANBALONE_PORT" \
A2O_BUNDLE_AGENT_PORT="$A2O_DEV_SAMPLE_AGENT_PORT" \
  docker compose \
    -p "$A2O_DEV_SAMPLE_COMPOSE_PROJECT" \
    -f docker/compose/a2o-kanbalone.yml \
    down -v

rm -rf "$storage_root"

git for-each-ref --format='%(refname)' refs/heads/a2o/work |
while IFS= read -r ref; do
  case "$ref" in
    refs/heads/a2o/work/A2ODevSampleJava*) git update-ref -d "$ref" ;;
  esac
done

git update-ref refs/heads/a2o/dev-sample-live HEAD
