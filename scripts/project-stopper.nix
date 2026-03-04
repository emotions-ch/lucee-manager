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
  STATUS=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].status // empty' "$REGISTRY_FILE")
  PORT=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].port // empty' "$REGISTRY_FILE")
  
  echo "Stopping Lucee project: $PROJECT_NAME"
  
  # Function to kill process tree
  kill_process_tree() {
    local pid=$1
    local signal=$2
    echo "Sending $signal to process tree starting at PID $pid..."
    
    # Kill the process and its children
    ${pkgs.procps}/bin/pkill -$signal -P "$pid" 2>/dev/null || true
    ${pkgs.coreutils}/bin/kill -$signal "$pid" 2>/dev/null || true
  }
  
  # Function to find Java processes on the project's port
  find_java_processes_on_port() {
    if [[ -n "$PORT" ]]; then
      echo "Looking for Java processes using port $PORT..."
      # Find processes listening on the port using ss
      local ss_output=$(${pkgs.iproute2}/bin/ss -tlnp 2>/dev/null | ${pkgs.gnugrep}/bin/grep ":$PORT " || true)
      
      if [[ -n "$ss_output" ]]; then
        # Extract PID from ss output (format: users:(("java",pid=12345,fd=80)))
        local pids=$(echo "$ss_output" | ${pkgs.gnugrep}/bin/grep -o 'pid=[0-9]*' | ${pkgs.gnugrep}/bin/grep -o '[0-9]*' || true)
        
        for pid in $pids; do
          # Check if it's a Java process
          if ${pkgs.procps}/bin/ps -p "$pid" -o comm= 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q java; then
            echo "Found Java process on port $PORT: PID $pid"
            echo "$pid"
          fi
        done
      fi
    fi
  }
  
  PROCESSES_KILLED=false
  
  # Try to kill using stored PID first
  if [[ -n "$PID" ]]; then
    echo "Attempting to stop using stored PID: $PID"
    if ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
      kill_process_tree "$PID" "TERM"
      
      # Wait for graceful shutdown
      echo "Waiting for graceful shutdown..."
      for i in {1..15}; do
        if ! ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
          echo "Process tree stopped gracefully."
          PROCESSES_KILLED=true
          break
        fi
        sleep 1
      done
      
      # Force kill if still running
      if ! $PROCESSES_KILLED && ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
        echo "Process still running, force killing..."
        kill_process_tree "$PID" "KILL"
        sleep 2
        if ! ${pkgs.procps}/bin/ps -p "$PID" > /dev/null 2>&1; then
          PROCESSES_KILLED=true
        fi
      fi
    else
      echo "Stored PID $PID is not running."
    fi
  fi
  
  # If PID method didn't work, find processes by port
  if ! $PROCESSES_KILLED; then
    echo "Searching for processes by port..."
    
    if [[ -n "$PORT" ]]; then
      # Get Java PIDs using port (stored in array-like string)
      JAVA_PIDS_STRING=$(find_java_processes_on_port)
      
      if [[ -n "$JAVA_PIDS_STRING" ]]; then
        # Convert to array and process each PID
        while read -r java_pid; do
          if [[ -n "$java_pid" && "$java_pid" =~ ^[0-9]+$ ]]; then
            echo "Stopping Java process PID: $java_pid"
            
            # Try graceful shutdown first
            if ${pkgs.coreutils}/bin/kill -TERM "$java_pid" 2>/dev/null; then
              echo "Sent SIGTERM to $java_pid, waiting..."
              for i in {1..15}; do
                if ! ${pkgs.procps}/bin/ps -p "$java_pid" > /dev/null 2>&1; then
                  echo "Process $java_pid stopped gracefully."
                  PROCESSES_KILLED=true
                  break
                fi
                sleep 1
              done
              
              # Force kill if still running
              if ${pkgs.procps}/bin/ps -p "$java_pid" > /dev/null 2>&1; then
                echo "Force killing process $java_pid..."
                ${pkgs.coreutils}/bin/kill -KILL "$java_pid" 2>/dev/null || true
                sleep 1
                if ! ${pkgs.procps}/bin/ps -p "$java_pid" > /dev/null 2>&1; then
                  PROCESSES_KILLED=true
                fi
              fi
            fi
          fi
        done <<< "$JAVA_PIDS_STRING"
      else
        echo "No Java processes found on port $PORT"
        PROCESSES_KILLED=true  # Consider it successful if nothing to kill
      fi
    else
      echo "No port information available for search"
      PROCESSES_KILLED=true
    fi
  fi
  
  # Update registry status
  lucee-track-port "$PROJECT_NAME" "stopped" "$REGISTRY_FILE"
  
  if $PROCESSES_KILLED; then
    echo "Project '$PROJECT_NAME' stopped successfully."
  else
    echo "Warning: Some processes may still be running. Check manually with: ps aux | grep java"
    exit 1
  fi
''