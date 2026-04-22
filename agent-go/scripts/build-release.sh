#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"
VERSION="${VERSION:-"dev"}"
PACKAGE_ARCHIVES="${PACKAGE_ARCHIVES:-1}"

if [[ -n "${TARGETS:-}" ]]; then
  read -r -a targets <<< "${TARGETS}"
else
  targets=(
    "darwin/amd64"
    "darwin/arm64"
    "linux/amd64"
    "linux/arm64"
  )
fi

mkdir -p "${DIST_DIR}"
: > "${DIST_DIR}/checksums.txt"
: > "${DIST_DIR}/release-manifest.jsonl"
bundle_name="a2o-agent-packages-${VERSION}.tar.gz"
cat > "${DIST_DIR}/package-compatibility.json" <<EOF
{
  "schema": "a2o-agent-package-compatibility/v1",
  "package_version": "${VERSION}",
  "runtime_version": "${VERSION}",
  "archive_manifest": "release-manifest.jsonl",
  "launcher_layout": "platform-bin-dir-v1"
}
EOF

sha256sum_or_shasum() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

for target in "${targets[@]}"; do
  goos="${target%%/*}"
  goarch="${target##*/}"
  out_dir="${DIST_DIR}/${goos}-${goarch}"

  mkdir -p "${out_dir}"
  echo "building ${goos}/${goarch}"
  (
    cd "${ROOT_DIR}"
    GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
      go build -trimpath -o "${out_dir}/a3-agent" ./cmd/a3-agent
    GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
      go build -trimpath -ldflags "-X main.version=${VERSION}" -o "${out_dir}/a3" ./cmd/a3
  )

  archive_name="a3-agent-${VERSION}-${goos}-${goarch}"
  if [[ "${PACKAGE_ARCHIVES}" == "1" ]]; then
    archive_path="${DIST_DIR}/${archive_name}.tar.gz"
    tar -C "${out_dir}" -czf "${archive_path}" "a3-agent"
    checksum="$(sha256sum_or_shasum "${archive_path}")"
    printf '%s  %s\n' "${checksum}" "$(basename "${archive_path}")" >> "${DIST_DIR}/checksums.txt"
    printf '{"version":"%s","goos":"%s","goarch":"%s","archive":"%s","sha256":"%s"}\n' \
      "${VERSION}" "${goos}" "${goarch}" "$(basename "${archive_path}")" "${checksum}" >> "${DIST_DIR}/release-manifest.jsonl"
  fi
done

if [[ "${PACKAGE_ARCHIVES}" == "1" ]]; then
  (
    cd "${DIST_DIR}"
    tar -czf "${bundle_name}" \
      "checksums.txt" \
      "release-manifest.jsonl" \
      "package-compatibility.json" \
      a3-agent-"${VERSION}"-*.tar.gz
  )
  bundle_sha256="$(sha256sum_or_shasum "${DIST_DIR}/${bundle_name}")"

  cat > "${DIST_DIR}/package-publication.json" <<EOF
{
  "schema": "a2o-agent-package-publication/v1",
  "version": "${VERSION}",
  "bundle_archive": "${bundle_name}",
  "bundle_archive_sha256": "${bundle_sha256}",
  "compatibility_contract": "package-compatibility.json",
  "archive_manifest": "release-manifest.jsonl",
  "checksums_file": "checksums.txt",
  "package_source_hint": "github-release-assets"
}
EOF
fi

echo "built artifacts in ${DIST_DIR}"
