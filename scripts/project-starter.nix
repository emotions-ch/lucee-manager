# Project starter - comprehensive start command
{ pkgs }:

pkgs.writeShellScriptBin "lucee-start-project" ''
  set -euo pipefail
  
  PROJECT_NAME="$1"
  REGISTRY_FILE="$2"
  
  # Check if project exists in registry
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
  
  # Step 1: Assign port if not already assigned
  CURRENT_PORT=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].port // empty' "$REGISTRY_FILE")
  if [[ -z "$CURRENT_PORT" || "$CURRENT_PORT" == "null" ]]; then
    echo "Step 1: Assigning port..."
    PORT=$(lucee-port-allocate "$PROJECT_NAME" "$REGISTRY_FILE")
    echo "  Assigned port: $PORT"
  else
    PORT="$CURRENT_PORT"
    echo "Step 1: Using existing port assignment: $PORT"
  fi
  
  # Step 2: Update Tomcat configuration
  echo "Step 2: Updating Tomcat configuration..."
  lucee-update-tomcat-config "$PROJECT_PATH" "$PORT"
  
  # Step 3: Generate nginx configuration
  echo "Step 3: Generating nginx configuration..."
  lucee-nginx-generate "$REGISTRY_FILE" "$HOME/.lucee-manager/nginx"
  
  # Step 4: Start nginx if not running
  echo "Step 4: Ensuring nginx is running..."
  if ! ${pkgs.procps}/bin/pgrep -f "nginx.*master.*lucee-manager" > /dev/null; then
    echo "  Starting nginx..."
    bash "$HOME/.lucee-manager/nginx/start-nginx.sh"
  else
    echo "  Nginx already running, reloading configuration..."
    ${pkgs.nginx}/bin/nginx -s reload -c "$HOME/.lucee-manager/nginx/nginx.conf" 2>/dev/null || true
  fi
  
  # Step 5: Update registry status to starting
  echo "Step 5: Updating registry status..."
  lucee-track-port "$PROJECT_NAME" "starting" "$REGISTRY_FILE"
  
  echo "Step 6: Starting Lucee instance in background..."
  echo "  Changing to project directory: $PROJECT_PATH"
  cd "$PROJECT_PATH"
  
  echo "  Running: nix run . (in background)"
  
  # Create logs directory
  mkdir -p "$HOME/.lucee-manager/logs"
  LOG_FILE="$HOME/.lucee-manager/logs/$PROJECT_NAME.log"
  
  # Start Lucee in background and capture PID
  nohup nix run . > "$LOG_FILE" 2>&1 &
  NIX_PID=$!
  
  echo "  Started with PID: $NIX_PID"
  echo "  Logs: $LOG_FILE"
  echo ""
  
  # Get project info for final message
  DOMAIN=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].domain' "$REGISTRY_FILE")
  
  echo "==================== Lucee Project Starting ===================="
  echo "Project: $PROJECT_NAME"
  echo "Port: $PORT"
  echo "Domain: $DOMAIN"
  echo "PID: $NIX_PID"
  echo "Direct access: http://localhost:$PORT"
  echo "Proxy access: http://$DOMAIN:8080"
  echo "Logs: $LOG_FILE"
  echo ""
  echo "To check status: lucee-manager list"
  echo "To stop: lucee-manager stop $PROJECT_NAME"
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
      exit 1
    fi
    
    sleep 2
  done
  
  # If we get here, timeout occurred
  echo "Timeout waiting for Lucee to start on port $PORT"
  echo "Process PID $NIX_PID may still be starting. Check logs: $LOG_FILE"
  echo "Run 'lucee-manager list' to check status"
''