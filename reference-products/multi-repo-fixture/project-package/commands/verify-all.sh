#!/usr/bin/env sh
set -eu

if [ -d repo_alpha ] && [ -d repo_beta ]; then
  repo_alpha_path=repo_alpha
  repo_beta_path=repo_beta
elif [ -n "${A2O_WORKER_REQUEST_PATH:-}" ] && [ -r "$A2O_WORKER_REQUEST_PATH" ]; then
  repo_alpha_path="$(ruby -rjson -e 'request = JSON.parse(File.read(ENV.fetch("A2O_WORKER_REQUEST_PATH"))); puts request.fetch("slot_paths").fetch("repo_alpha")')"
  repo_beta_path="$(ruby -rjson -e 'request = JSON.parse(File.read(ENV.fetch("A2O_WORKER_REQUEST_PATH"))); puts request.fetch("slot_paths").fetch("repo_beta")')"
else
  echo "verify-all requires repo_alpha/repo_beta directories or A2O_WORKER_REQUEST_PATH with slot_paths" >&2
  exit 1
fi

(cd "$repo_alpha_path" && npm test)
(cd "$repo_beta_path" && npm test)
