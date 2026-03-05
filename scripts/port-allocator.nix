# Port allocator - assigns available ports to projects
{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-port-allocate" ''
  set -euo pipefail
  
  PROJECT_NAME="$1"
  
  if [[ ! -f "${conf.reg.path}" ]]; then
    echo "Registry not found. Run 'lucee-scan' first."
    exit 1
  fi
  
  # Check if project already has a port
  EXISTING_PORT=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].port // empty' "${conf.reg.path}")
  if [[ -n "$EXISTING_PORT" ]]; then
    echo "$EXISTING_PORT"
    exit 0
  fi
  
  # Get port range from registry
  PORT_START=$(${pkgs.jq}/bin/jq -r '.portRange.start' "${conf.reg.path}")
  PORT_END=$(${pkgs.jq}/bin/jq -r '.portRange.end' "${conf.reg.path}")
  
  # Get all assigned ports
  ASSIGNED_PORTS=$(${pkgs.jq}/bin/jq -r '[.projects[].port // empty] | map(select(. != "")) | sort | .[]' "${conf.reg.path}")
  
  # Find the first available port
  for ((port=PORT_START; port<=PORT_END; port++)); do
    PORT_IN_USE=false
    
    # Check if port is assigned in registry
    if echo "$ASSIGNED_PORTS" | grep -q "^$port$"; then
      PORT_IN_USE=true
    fi
    
    # Check if port is in use by system (including shutdown port)
    SHUTDOWN_PORT=$((port + 1000))
    if ${pkgs.nettools}/bin/netstat -tuln 2>/dev/null | grep -q ":$port "; then
      PORT_IN_USE=true
    fi
    if ${pkgs.nettools}/bin/netstat -tuln 2>/dev/null | grep -q ":$SHUTDOWN_PORT "; then
      PORT_IN_USE=true
    fi
    
    if ! $PORT_IN_USE; then
      # Assign this port to the project
      ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                        --arg port "$port" \
                        '.projects[$name].port = ($port | tonumber)' \
                        "${conf.reg.path}" > "${conf.reg.path}.tmp"
      
      mv "${conf.reg.path}.tmp" "${conf.reg.path}"
      echo "$port"
      exit 0
    fi
  done
  
  echo "No available ports in range $PORT_START-$PORT_END"
  exit 1
''
