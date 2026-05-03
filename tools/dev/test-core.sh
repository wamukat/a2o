#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${A2O_TEST_LOG_DIR:-"${ROOT_DIR}/.work/test-core"}"
RUBY_CMD="${A2O_TEST_RUBY_CMD:-bundle exec rspec}"
RUBY_SHARDS="${A2O_TEST_RUBY_SHARDS:-1}"
RUBY_SHARD_GRANULARITY="${A2O_TEST_RUBY_SHARD_GRANULARITY:-example}"
GO_CMD="${A2O_TEST_GO_CMD:-cd agent-go && go test ./...}"
KANBAN_PY_CMD="${A2O_TEST_KANBAN_PY_CMD:-python3 -m unittest discover -s tools/kanban/tests}"
mkdir -p "${LOG_DIR}"

if ! [[ "${RUBY_SHARDS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "A2O_TEST_RUBY_SHARDS must be a positive integer, got: ${RUBY_SHARDS}" >&2
  exit 2
fi

case "${RUBY_SHARD_GRANULARITY}" in
  example|file)
    ;;
  *)
    echo "A2O_TEST_RUBY_SHARD_GRANULARITY must be 'example' or 'file', got: ${RUBY_SHARD_GRANULARITY}" >&2
    exit 2
    ;;
esac

run_suite() {
  local label="$1"
  shift
  local log_path="${LOG_DIR}/${label}.log"
  local start
  local end
  local status

  start="$(date +%s)"
  echo "test_core_start suite=${label} log=${log_path}"
  (
    cd "${ROOT_DIR}" || exit 1
    "$@"
  ) >"${log_path}" 2>&1
  status=$?
  end="$(date +%s)"
  echo "test_core_done suite=${label} status=${status} seconds=$((end - start)) log=${log_path}"
  if [[ "${status}" -ne 0 ]]; then
    echo "test_core_failure_tail suite=${label}" >&2
    tail -80 "${log_path}" >&2
  fi
  return "${status}"
}

run_ruby_shard() {
  local shard_file="$1"
  local ruby_cmd="$2"
  local spec_file
  local quoted_spec
  local quoted_specs=""

  while IFS= read -r spec_file; do
    printf -v quoted_spec "%q" "${spec_file}"
    quoted_specs="${quoted_specs} ${quoted_spec}"
  done <"${shard_file}"

  if [[ -z "${quoted_specs}" ]]; then
    return 0
  fi

  if [[ -z "${GIT_CONFIG_GLOBAL:-}" ]]; then
    export GIT_CONFIG_GLOBAL="${shard_file%.lst}.gitconfig"
    : >"${GIT_CONFIG_GLOBAL}"
  fi

  bash -c "${ruby_cmd}${quoted_specs}"
}

build_ruby_file_shards() {
  local shard_dir="$1"
  local shard_count="$2"
  local index=0
  local shard_number
  local spec_file

  rm -rf "${shard_dir}"
  mkdir -p "${shard_dir}"

  while IFS= read -r spec_file; do
    shard_number=$((index % shard_count + 1))
    printf "%s\n" "${spec_file}" >>"${shard_dir}/ruby_${shard_number}.lst"
    index=$((index + 1))
  done < <(find spec -type f -name '*_spec.rb' | LC_ALL=C sort)

  if [[ "${index}" -eq 0 ]]; then
    echo "No Ruby spec files found under spec/" >&2
    return 1
  fi
}

build_ruby_example_shards() {
  local shard_dir="$1"
  local shard_count="$2"
  local dry_run_json="${shard_dir}/rspec-dry-run.json"
  local quoted_json

  rm -rf "${shard_dir}"
  mkdir -p "${shard_dir}"
  printf -v quoted_json "%q" "${dry_run_json}"

  (
    cd "${ROOT_DIR}" || exit 1
    bash -c "${RUBY_CMD} --dry-run --format json > ${quoted_json}"
  ) || return 1

  ruby -rjson -e '
    data = JSON.parse(File.read(ARGV.fetch(0)))
    shard_dir = ARGV.fetch(1)
    shard_count = Integer(ARGV.fetch(2))
    examples = data.fetch("examples").map do |example|
      file_path = example.fetch("file_path")
      line_number = example.fetch("line_number")
      "#{file_path}:#{line_number}"
    end.uniq
    raise "No Ruby examples discovered by rspec dry-run" if examples.empty?

    examples.each_with_index do |selector, index|
      shard_number = (index % shard_count) + 1
      File.open(File.join(shard_dir, "ruby_#{shard_number}.lst"), "a") do |file|
        file.puts(selector)
      end
    end
  ' "${dry_run_json}" "${shard_dir}" "${shard_count}"
}

pids=()

if [[ "${RUBY_SHARDS}" -eq 1 ]]; then
  run_suite ruby "bash" "-c" "${RUBY_CMD}" &
  pids+=("$!")
else
  ruby_shard_dir="${LOG_DIR}/ruby-shards"
  case "${RUBY_SHARD_GRANULARITY}" in
    example)
      if ! build_ruby_example_shards "${ruby_shard_dir}" "${RUBY_SHARDS}"; then
        exit 1
      fi
      ;;
    file)
      if ! build_ruby_file_shards "${ruby_shard_dir}" "${RUBY_SHARDS}"; then
        exit 1
      fi
      ;;
  esac

  for shard_file in "${ruby_shard_dir}"/ruby_*.lst; do
    [[ -s "${shard_file}" ]] || continue
    shard_label="$(basename "${shard_file}" .lst)"
    run_suite "${shard_label}" run_ruby_shard "${shard_file}" "${RUBY_CMD}" &
    pids+=("$!")
  done
fi

run_suite go "bash" "-c" "${GO_CMD}" &
pids+=("$!")

run_suite kanban_py "bash" "-c" "${KANBAN_PY_CMD}" &
pids+=("$!")

overall=0
for pid in "${pids[@]}"; do
  if ! wait "${pid}"; then
    overall=1
  fi
done

exit "${overall}"
