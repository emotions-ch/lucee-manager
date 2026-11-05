# Project stopper - stops a running Lucee instance
{ pkgs }:

pkgs.writeShellScriptBin "lucee-stop-project" ''
  set -euo pipefail

  PROJECT_NAME="$1"
  REGISTRY_FILE="$2"

  # Check if project exists in registry
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Registry not found."
    exit 1
  fi

  # Get project info
  PID=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].pid // empty' "$REGISTRY_FILE")
  PORT=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].port // empty' "$REGISTRY_FILE")

  echo "Stopping Lucee project: $PROJECT_NAME"

  # Kill a process and all its descendants with SIGKILL (children first)
  kill_process_tree() {
    local pid=$1
    local child
    for child in $(${pkgs.procps}/bin/pgrep -P "$pid" 2>/dev/null || true); do
      kill_process_tree "$child"
    done
    ${pkgs.coreutils}/bin/kill -KILL "$pid" 2>/dev/null || true
  }

  # Find Java PIDs listening on the project's port
  find_java_processes_on_port() {
    if [[ -n "$PORT" ]]; then
      local pids
      pids=$(${pkgs.iproute2}/bin/ss -tlnp 2>/dev/null | ${pkgs.gnugrep}/bin/grep ":$PORT " | ${pkgs.gnugrep}/bin/grep -o 'pid=[0-9]*' | ${pkgs.gnugrep}/bin/grep -o '[0-9]*' || true)
      local pid
      for pid in $pids; do
        if ${pkgs.procps}/bin/ps -p "$pid" -o comm= 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q java; then
          echo "$pid"
        fi
      done
    fi
  }

  # Kill the stored PID and its whole tree
  if [[ -n "$PID" ]]; then
    if ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
      echo "Killing process tree at PID $PID..."
      kill_process_tree "$PID"
    else
      echo "Stored PID $PID is not running."
    fi
  fi

  # Kill anything still listening on the port
  if [[ -n "$PORT" ]]; then
    for java_pid in $(find_java_processes_on_port); do
      echo "Killing Java process on port $PORT: PID $java_pid"
      kill_process_tree "$java_pid"
    done
  fi

  # Update registry status
  lucee-track-port "$PROJECT_NAME" "stopped" "$REGISTRY_FILE"

  sleep 1
  REMAINING=$(find_java_processes_on_port)
  if [[ -n "$PID" ]] && ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
    REMAINING="$PID $REMAINING"
  fi

  if [[ -z "$REMAINING" ]]; then
    echo "Project '$PROJECT_NAME' stopped successfully."
  else
    echo "Warning: Some processes may still be running: $REMAINING"
    exit 1
  fi
''
