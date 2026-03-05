# Project starter - comprehensive start command
{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-start-project" ''
  set -euo pipefail
  
  PROJECT_NAME="$1"
  REGISTRY_FILE="$2"
  
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Registry not found. Run 'lucee-manager scan' first."
    exit 1
  fi
  
  PROJECT_PATH=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].path // empty' "$REGISTRY_FILE")
  if [[ -z "$PROJECT_PATH" ]]; then
    echo "Project '$PROJECT_NAME' not found in registry."
    echo "Run 'lucee-manager scan' to discover projects first."
    exit 1
  fi
  
  echo "Starting Lucee project: $PROJECT_NAME"
  echo "Project path: $PROJECT_PATH"
  
  # Convert relative path to absolute
  if [[ ! "$PROJECT_PATH" =~ ^/ ]]; then
    PROJECT_PATH="$PWD/$PROJECT_PATH"
  fi
  
  #Assign port if not already assigned
  CURRENT_PORT=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].port // empty' "$REGISTRY_FILE")
  if [[ -z "$CURRENT_PORT" || "$CURRENT_PORT" == "null" ]]; then
    echo "Assigning port..."
    PORT=$(lucee-port-allocate "$PROJECT_NAME" "$REGISTRY_FILE")
    echo "  Assigned port: $PORT"
  else
    PORT="$CURRENT_PORT"
    echo "Using existing port assignment: $PORT"
  fi
  
  lucee-update-tomcat-config "$PROJECT_PATH" "$PORT"
  lucee-nginx-generate "$REGISTRY_FILE" "${conf.nginx}"
  
  # Step 4: Start nginx if not running
  if ! ${pkgs.procps}/bin/pgrep -f "nginx.*master.*lucee-manager" > /dev/null; then
    echo "  Starting nginx..."
    bash "${conf.nginx}/start-nginx.sh"
  else
    echo "  Nginx already running, reloading configuration..."
    ${pkgs.nginx}/bin/nginx -s reload -c "${conf.nginx}/nginx.conf" 2>/dev/null || true
  fi
  
  echo "Updating registry status..."
  lucee-track-port "$PROJECT_NAME" "starting" "$REGISTRY_FILE"
  
  cd "$PROJECT_PATH"
  
  echo "Running: nix run $PROJECT_PATH"
  
  # Create logs directory
  mkdir -p "${conf.logs}"
  LOG_FILE="${conf.logs}/$PROJECT_NAME.log"
  
  # Start Lucee in background and capture PID
  nohup nix run . > "$LOG_FILE" 2>&1 &
  NIX_PID=$!
  
  # Get project info for final message
  DOMAIN=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].domain' "$REGISTRY_FILE")

  echo ""
  echo "==================== Lucee Project Starting ===================="
  echo "Project: $PROJECT_NAME"
  echo "Port: $PORT"
  echo "Domain: $DOMAIN"
  echo "PID: $NIX_PID"
  echo "Direct access: http://localhost:$PORT"
  echo "Proxy access: http://$DOMAIN:8080"
  echo "Logs: $LOG_FILE"
  echo "=============================================================="
  echo ""
  
  # Wait for the service to be ready and update status with PID
  echo "Waiting for Lucee to start..."
  for i in {1..30}; do
    if ${pkgs.nettools}/bin/netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
      echo "Lucee is ready!"
      lucee-track-port "$PROJECT_NAME" "running" "$REGISTRY_FILE" "$NIX_PID"
      echo "Project '$PROJECT_NAME' is now running in background."
      exit 0
    fi
    
    # Check if process is still running
    if ! ${pkgs.procps}/bin/ps -p "$NIX_PID" > /dev/null 2>&1; then
      echo "Process $NIX_PID stopped unexpectedly. Check logs: $LOG_FILE"
      lucee-track-port "$PROJECT_NAME" "stopped" "$REGISTRY_FILE"
      cat $LOG_FILE | tail -n 5
      exit 1
    fi
    
    sleep 2
  done
  
  # If we get here, timeout occurred
  echo "Timeout waiting for Lucee to start on port $PORT"
  echo "Process PID $NIX_PID may still be starting. Check logs: $LOG_FILE"
  echo "Run 'lucee-manager list' to check status"
''
