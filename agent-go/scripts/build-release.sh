#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"

targets=(
  "darwin/amd64"
  "darwin/arm64"
  "linux/amd64"
  "linux/arm64"
  "windows/amd64"
)

mkdir -p "${DIST_DIR}"

for target in "${targets[@]}"; do
  goos="${target%%/*}"
  goarch="${target##*/}"
  out_dir="${DIST_DIR}/${goos}-${goarch}"
  binary_name="a3-agent"
  if [[ "${goos}" == "windows" ]]; then
    binary_name="a3-agent.exe"
  fi

  mkdir -p "${out_dir}"
  echo "building ${goos}/${goarch}"
  (
    cd "${ROOT_DIR}"
    GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
      go build -trimpath -o "${out_dir}/${binary_name}" ./cmd/a3-agent
  )
done

echo "built artifacts in ${DIST_DIR}"
