# Port tracker - updates project status and PID tracking
{ pkgs }:

pkgs.writeShellScriptBin "lucee-track-port" ''
  set -euo pipefail
  
  PROJECT_NAME="$1"
  ACTION="''${2:-running}"  # running, starting, stopped
  REGISTRY_FILE="''${3:-$HOME/.lucee-manager/registry.json}"
  PID="''${4:-}"  # Optional PID for running status
  
  if [[ ! -f "$REGISTRY_FILE" ]]; then
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
                          "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
      else
        ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                          --arg timestamp "$(date -Iseconds)" \
                          '.projects[$name].status = "running" | .projects[$name].lastSeen = $timestamp' \
                          "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
      fi
      ;;
    starting)
      ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                        --arg timestamp "$(date -Iseconds)" \
                        '.projects[$name].status = "starting" | .projects[$name].lastSeen = $timestamp' \
                        "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
      ;;
    stopped)
      ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                        '.projects[$name].status = "stopped" | del(.projects[$name].pid)' \
                        "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
      ;;
    *)
      echo "Invalid action: $ACTION"
      exit 1
      ;;
  esac
  
  mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
''