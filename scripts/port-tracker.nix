# Port tracker - updates project status and PID tracking
{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-track-port" ''
  set -euo pipefail
  
  PROJECT_NAME="$1"
  ACTION="''${2:-running}"  # running, starting, stopped
  PID="''${4:-}"  # Optional PID for running status
  
  if [[ ! -f "${conf.reg.path}" ]]; then
    echo "Registry not found."
    exit 1
  fi
  
  case "$ACTION" in
    running)
      if [[ -n "$PID" ]]; then
        ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                          --arg timestamp "$(date -Iseconds)" \
                          --arg pid "$PID" \
                          '.projects[$name].status = "running" | .projects[$name].lastSeen = $timestamp | .projects[$name].pid = ($pid | tonumber)' \
                          "${conf.reg.path}" > "${conf.reg.path}.tmp"
      else
        ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                          --arg timestamp "$(date -Iseconds)" \
                          '.projects[$name].status = "running" | .projects[$name].lastSeen = $timestamp' \
                          "${conf.reg.path}" > "${conf.reg.path}.tmp"
      fi
      ;;
    starting)
      ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                        --arg timestamp "$(date -Iseconds)" \
                        '.projects[$name].status = "starting" | .projects[$name].lastSeen = $timestamp' \
                        "${conf.reg.path}" > "${conf.reg.path}.tmp"
      ;;
    stopped)
      ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                        '.projects[$name].status = "stopped" | del(.projects[$name].pid)' \
                        "${conf.reg.path}" > "${conf.reg.path}.tmp"
      ;;
    *)
      echo "Invalid action: $ACTION"
      exit 1
      ;;
  esac
  
  mv "${conf.reg.path}.tmp" "${conf.reg.path}"
''
