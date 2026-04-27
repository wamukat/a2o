#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"${ROOT_DIR}/dist"}"
VERSION="${VERSION:-"dev"}"
PACKAGE_ARCHIVES="${PACKAGE_ARCHIVES:-1}"
PUBLICATION_BUNDLE_ARCHIVE="${PUBLICATION_BUNDLE_ARCHIVE:-}"
PUBLICATION_BUNDLE_URL="${PUBLICATION_BUNDLE_URL:-}"
PUBLICATION_BUNDLE_SHA256="${PUBLICATION_BUNDLE_SHA256:-}"

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
      go build -trimpath -o "${out_dir}/a2o-agent" ./cmd/a3-agent
    GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=0 \
      go build -trimpath -ldflags "-X main.version=${VERSION}" -o "${out_dir}/a2o" ./cmd/a3
  )

  archive_name="a2o-agent-${VERSION}-${goos}-${goarch}"
  if [[ "${PACKAGE_ARCHIVES}" == "1" ]]; then
    archive_path="${DIST_DIR}/${archive_name}.tar.gz"
    tar -C "${out_dir}" -czf "${archive_path}" "a2o-agent"
    checksum="$(sha256sum_or_shasum "${archive_path}")"
    printf '%s  %s\n' "${checksum}" "$(basename "${archive_path}")" >> "${DIST_DIR}/checksums.txt"
    printf '{"version":"%s","goos":"%s","goarch":"%s","archive":"%s","sha256":"%s"}\n' \
      "${VERSION}" "${goos}" "${goarch}" "$(basename "${archive_path}")" "${checksum}" >> "${DIST_DIR}/release-manifest.jsonl"
  fi
done

bundle_sha256=""
if [[ "${PACKAGE_ARCHIVES}" == "1" ]]; then
  bundle_items=(
    "checksums.txt"
    "release-manifest.jsonl"
    "package-compatibility.json"
  )
  for target in "${targets[@]}"; do
    bundle_items+=("${target/\//-}")
    bundle_items+=("a2o-agent-${VERSION}-${target/\//-}.tar.gz")
  done
  (
    cd "${DIST_DIR}"
    tar -czf "${bundle_name}" "${bundle_items[@]}"
  )
  bundle_sha256="$(sha256sum_or_shasum "${DIST_DIR}/${bundle_name}")"
fi

if [[ "${PACKAGE_ARCHIVES}" == "1" || -n "${PUBLICATION_BUNDLE_URL}" ]]; then
  publication_bundle_archive="${PUBLICATION_BUNDLE_ARCHIVE:-${bundle_name}}"
  publication_bundle_url="${PUBLICATION_BUNDLE_URL:-https://github.com/wamukat/a2o/releases/download/v${VERSION}/${publication_bundle_archive}}"
  publication_bundle_sha256="${PUBLICATION_BUNDLE_SHA256:-${bundle_sha256}}"
  if [[ -z "${publication_bundle_sha256}" ]]; then
    echo "PUBLICATION_BUNDLE_SHA256 is required when PACKAGE_ARCHIVES=0 and PUBLICATION_BUNDLE_URL is set" >&2
    exit 1
  fi
  cat > "${DIST_DIR}/package-publication.json" <<EOF
{
  "schema": "a2o-agent-package-publication/v1",
  "version": "${VERSION}",
  "bundle_archive": "${publication_bundle_archive}",
  "bundle_url": "${publication_bundle_url}",
  "bundle_archive_sha256": "${publication_bundle_sha256}",
  "compatibility_contract": "package-compatibility.json",
  "archive_manifest": "release-manifest.jsonl",
  "checksums_file": "checksums.txt",
  "package_source_hint": "github-release-assets"
}
EOF
fi

echo "built artifacts in ${DIST_DIR}"
