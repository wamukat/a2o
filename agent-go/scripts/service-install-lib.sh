#!/usr/bin/env bash

detect_service_manager() {
  if [[ "${SERVICE_MANAGER}" != "auto" ]]; then
    printf '%s\n' "${SERVICE_MANAGER}"
    return
  fi
  case "$(uname -s)" in
    Darwin)
      printf 'launchd\n'
      ;;
    Linux)
      printf 'systemd\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

install_service_template() {
  local manager="$1"
  local output_path="$2"
  local -a args
  args=(
    service-template "${manager}"
    -config "${CONFIG_PATH}"
    -binary "${BIN_DIR}/a3-agent"
    -label "${SERVICE_LABEL}"
    -poll-interval "${POLL_INTERVAL}"
  )
  if [[ -n "${WORKING_DIR}" ]]; then
    args+=(-working-dir "${WORKING_DIR}")
  fi
  "${BIN_DIR}/a3-agent" "${args[@]}" > "${output_path}"
  echo "installed service template ${output_path}"
}

enable_systemd_service() {
  local unit_name="$1"
  systemctl --user daemon-reload
  systemctl --user enable --now "${unit_name}"
}

enable_launchd_service() {
  local plist_path="$1"
  local service_domain="gui/$(id -u)"
  launchctl bootout "${service_domain}" "${plist_path}" >/dev/null 2>&1 || true
  launchctl bootstrap "${service_domain}" "${plist_path}"
  launchctl enable "${service_domain}/${SERVICE_LABEL}"
  launchctl kickstart -k "${service_domain}/${SERVICE_LABEL}"
}

install_agent_service_if_requested() {
  if [[ "${INSTALL_SERVICE}" != "1" ]]; then
    return
  fi
  if [[ -z "${CONFIG_PATH}" ]]; then
    echo "CONFIG_PATH is required when INSTALL_SERVICE=1" >&2
    exit 2
  fi
  manager="$(detect_service_manager)"
  case "${manager}" in
    systemd)
      service_dir="${SERVICE_DIR:-"${HOME}/.config/systemd/user"}"
      mkdir -p "${service_dir}"
      unit_name="${SERVICE_LABEL}.service"
      output_path="${service_dir}/${unit_name}"
      install_service_template "${manager}" "${output_path}"
      if [[ "${ENABLE_SERVICE}" == "1" ]]; then
        enable_systemd_service "${unit_name}"
        echo "enabled ${unit_name}"
      else
        echo "to enable: systemctl --user daemon-reload && systemctl --user enable --now ${unit_name}"
      fi
      ;;
    launchd)
      service_dir="${SERVICE_DIR:-"${HOME}/Library/LaunchAgents"}"
      mkdir -p "${service_dir}"
      output_path="${service_dir}/${SERVICE_LABEL}.plist"
      install_service_template "${manager}" "${output_path}"
      if [[ "${ENABLE_SERVICE}" == "1" ]]; then
        enable_launchd_service "${output_path}"
        echo "enabled ${SERVICE_LABEL}"
      else
        echo "to enable: launchctl bootstrap gui/$(id -u) ${output_path} && launchctl enable gui/$(id -u)/${SERVICE_LABEL} && launchctl kickstart -k gui/$(id -u)/${SERVICE_LABEL}"
      fi
      ;;
    none)
      echo "service manager is not available on this OS" >&2
      exit 2
      ;;
    *)
      echo "unsupported SERVICE_MANAGER=${manager}" >&2
      exit 2
      ;;
  esac
}
