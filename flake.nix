{
  description = "Lucee Reverse Proxy Manager - Automatic port management and nginx configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Project scanner - discovers Lucee projects in a directory
        projectScanner = pkgs.writeShellScriptBin "lucee-scan" ''
          set -euo pipefail
          
          PROJECTS_DIR="''${1:-$PWD}"
          REGISTRY_FILE="''${2:-$HOME/.lucee-manager/registry.json}"
          
          # Ensure registry directory exists
          mkdir -p "$(dirname "$REGISTRY_FILE")"
          
          # Initialize registry if it doesn't exist
          if [[ ! -f "$REGISTRY_FILE" ]]; then
            echo '{"projects": {}, "lastScan": null, "portRange": {"start": 8100, "end": 8199}}' > "$REGISTRY_FILE"
          fi
          
          echo "Scanning for Lucee projects in: $PROJECTS_DIR"
          
          # Find all directories with flake.nix containing lucee-nix
          find "$PROJECTS_DIR" -maxdepth 2 -name "flake.nix" -exec grep -l "lucee-nix" {} \; | while read -r flake_file; do
            project_dir="$(dirname "$flake_file")"
            project_name="$(basename "$project_dir")"
            
            echo "Found Lucee project: $project_name at $project_dir"
            
            # Check if project has wwwroot directory
            if [[ -d "$project_dir/wwwroot" ]]; then
              echo "  -> Confirmed with wwwroot directory"
              
              # Check for lucee-manager.json configuration
              CONFIG_FILE="$project_dir/lucee-instance/conf/lucee-manager.json"
              if [[ -f "$CONFIG_FILE" ]]; then
                echo "  -> Found lucee-manager.json configuration"
                
                # Read project name and domain from config file
                CONFIGURED_NAME=$(${pkgs.jq}/bin/jq -r '.projectName // .project // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
                CONFIGURED_DOMAIN=$(${pkgs.jq}/bin/jq -r '.domain // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
                
                # Use configured values if available, otherwise use defaults
                PROJECT_NAME_TO_USE="''${CONFIGURED_NAME:-$project_name}"
                PROJECT_DOMAIN_TO_USE="''${CONFIGURED_DOMAIN:-$project_name.local}"
                
                echo "  -> Project name: $PROJECT_NAME_TO_USE"
                echo "  -> Domain: $PROJECT_DOMAIN_TO_USE"
              else
                echo "  -> Using defaults (no lucee-manager.json found)"
                PROJECT_NAME_TO_USE="$project_name"
                PROJECT_DOMAIN_TO_USE="$project_name.local"
              fi
              
              # Register or update project in registry  
              ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME_TO_USE" \
                                --arg path "$project_dir" \
                                --arg discovered "$(date -Iseconds)" \
                                --arg domain "$PROJECT_DOMAIN_TO_USE" \
                                '.projects[$name] = {
                                  path: $path,
                                  discovered: $discovered,
                                  port: (.projects[$name].port // null),
                                  status: (.projects[$name].status // "discovered"),
                                  domain: $domain
                                }' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
              mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
            fi
          done
          
          # Update last scan timestamp
          ${pkgs.jq}/bin/jq '.lastScan = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
          mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
          
          echo "Scan complete. Registry updated: $REGISTRY_FILE"
          ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | "  " + .key + " -> " + .value.path' "$REGISTRY_FILE"
        '';

        # Port allocator - assigns available ports to projects
        portAllocator = pkgs.writeShellScriptBin "lucee-port-allocate" ''
          set -euo pipefail
          
          PROJECT_NAME="$1"
          REGISTRY_FILE="''${2:-$HOME/.lucee-manager/registry.json}"
          
          if [[ ! -f "$REGISTRY_FILE" ]]; then
            echo "Registry not found. Run 'lucee-scan' first."
            exit 1
          fi
          
          # Check if project exists in registry
          if ! ${pkgs.jq}/bin/jq -e ".projects[\"$PROJECT_NAME\"]" "$REGISTRY_FILE" > /dev/null; then
            echo "Project '$PROJECT_NAME' not found in registry."
            exit 1
          fi
          
          # Check if port already assigned
          CURRENT_PORT=$(${pkgs.jq}/bin/jq -r ".projects[\"$PROJECT_NAME\"].port // empty" "$REGISTRY_FILE")
          if [[ -n "$CURRENT_PORT" && "$CURRENT_PORT" != "null" ]]; then
            # Verify port is still available
            if ! ss -ln | grep -q ":$CURRENT_PORT "; then
              echo "$CURRENT_PORT"
              exit 0
            else
              echo "Port $CURRENT_PORT is in use, reassigning..." >&2
            fi
          fi
          
          # Get port range from registry
          PORT_START=$(${pkgs.jq}/bin/jq -r '.portRange.start // 8100' "$REGISTRY_FILE")
          PORT_END=$(${pkgs.jq}/bin/jq -r '.portRange.end // 8199' "$REGISTRY_FILE")
          
          # Get all assigned ports
          ASSIGNED_PORTS=$(${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | .value.port' "$REGISTRY_FILE" | sort -n)
          
          # Find available port
          for PORT in $(seq $PORT_START $PORT_END); do
            # Check if port is not assigned to any project
            if ! echo "$ASSIGNED_PORTS" | grep -q "^$PORT$"; then
              # Check if port is not in use by system
              if ! ss -ln | grep -q ":$PORT "; then
                # Update registry with assigned port
                ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                                  --arg port "$PORT" \
                                  '.projects[$name].port = ($port | tonumber)' \
                                  "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
                mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
                
                echo "$PORT"
                exit 0
              fi
            fi
          done
          
          echo "No available ports in range $PORT_START-$PORT_END" >&2
          exit 1
        '';

        # Port tracker - updates registry with running status
        portTracker = pkgs.writeShellScriptBin "lucee-track-port" ''
          set -euo pipefail
          
          PROJECT_NAME="$1"
          ACTION="''${2:-running}"  # running, stopped
          REGISTRY_FILE="''${3:-$HOME/.lucee-manager/registry.json}"
          
          if [[ ! -f "$REGISTRY_FILE" ]]; then
            echo "Registry not found."
            exit 1
          fi
          
          case "$ACTION" in
            running)
              ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                                --arg timestamp "$(date -Iseconds)" \
                                '.projects[$name].status = "running" | .projects[$name].lastSeen = $timestamp' \
                                "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
              ;;
            starting)
              ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                                --arg timestamp "$(date -Iseconds)" \
                                '.projects[$name].status = "starting" | .projects[$name].lastSeen = $timestamp' \
                                "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
              ;;
            stopped)
              ${pkgs.jq}/bin/jq --arg name "$PROJECT_NAME" \
                                '.projects[$name].status = "stopped"' \
                                "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
              ;;
            *)
              echo "Invalid action: $ACTION"
              exit 1
              ;;
          esac
          
          mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
        '';

        # Nginx configuration generator
        nginxGenerator = pkgs.writeShellScriptBin "lucee-nginx-generate" ''
          set -euo pipefail
          
          REGISTRY_FILE="''${1:-$HOME/.lucee-manager/registry.json}"
          OUTPUT_DIR="''${2:-$HOME/.lucee-manager/nginx}"
          
          if [[ ! -f "$REGISTRY_FILE" ]]; then
            echo "Registry not found. Run 'lucee-scan' first."
            exit 1
          fi
          
          mkdir -p "$OUTPUT_DIR/sites"
          
          echo "Generating nginx configuration for Lucee reverse proxy..."
          
          # Generate main nginx.conf
          cat > "$OUTPUT_DIR/nginx.conf" <<'EOF'
worker_processes auto;
pid /tmp/nginx.pid;
error_log /tmp/nginx_error.log;

events {
    worker_connections 1024;
}

http {
    # Basic MIME types
    types {
        text/html                             html htm shtml;
        text/css                              css;
        application/javascript                js;
        image/jpeg                           jpeg jpg;
        image/png                            png;
        image/gif                            gif;
        image/svg+xml                        svg svgz;
        application/json                     json;
        application/pdf                      pdf;
        application/zip                      zip;
    }
    
    default_type application/octet-stream;
    
    access_log /tmp/nginx_access.log;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # Handle long server names
    server_names_hash_bucket_size 128;
    
    # Include all site configurations
    include NGINX_SITES_PATH/*.conf;
    
    # Default server
    server {
        listen 8080 default_server;
        server_name _;
        
        location / {
            return 200 "Lucee Reverse Proxy - Available projects:\n\n";
            add_header Content-Type text/plain;
        }
        
        location /status {
            access_log off;
            return 200 "OK\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF
          
          # Replace NGINX_SITES_PATH with actual path
          sed -i "s|NGINX_SITES_PATH|$OUTPUT_DIR/sites|g" "$OUTPUT_DIR/nginx.conf"
          
          # Generate site configurations for each project with assigned ports
          ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | @json' "$REGISTRY_FILE" | while read -r project_json; do
            PROJECT_NAME=$(echo "$project_json" | ${pkgs.jq}/bin/jq -r '.key')
            PROJECT_DATA=$(echo "$project_json" | ${pkgs.jq}/bin/jq -r '.value')
            PROJECT_PORT=$(echo "$PROJECT_DATA" | ${pkgs.jq}/bin/jq -r '.port')
            PROJECT_DOMAIN=$(echo "$PROJECT_DATA" | ${pkgs.jq}/bin/jq -r '.domain')
            
            echo "  -> $PROJECT_NAME ($PROJECT_DOMAIN -> localhost:$PROJECT_PORT)"
            
            # Generate nginx site configuration
            NGINX_CONFIG="$OUTPUT_DIR/sites/$PROJECT_NAME.conf"
            
            cat > "$NGINX_CONFIG" <<'NGINXEOF'
# Lucee project: PROJECT_NAME_PLACEHOLDER
upstream lucee_PROJECT_NAME_PLACEHOLDER {
    server 127.0.0.1:PROJECT_PORT_PLACEHOLDER max_fails=3 fail_timeout=30s;
    keepalive 4;
}

server {
    listen 8080;
    server_name PROJECT_DOMAIN_PLACEHOLDER;
    
    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    
    # Logging
    access_log /tmp/nginx_PROJECT_NAME_PLACEHOLDER_access.log;
    error_log /tmp/nginx_PROJECT_NAME_PLACEHOLDER_error.log;
    
    # Main location - proxy to Lucee
    location / {
        proxy_pass http://lucee_PROJECT_NAME_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # Timeouts for Lucee applications
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;  # Longer timeout for CFML processing
        
        # Buffering
        proxy_buffering on;
        proxy_buffer_size 8k;
        proxy_buffers 16 8k;
        
        # Handle large uploads
        client_max_body_size 100M;
    }
    
    # Static assets with caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|pdf|zip)$ {
        proxy_pass http://lucee_PROJECT_NAME_PLACEHOLDER;
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Vary Accept-Encoding;
    }
    
    # CFML files - no caching
    location ~* \.(cfm|cfc)$ {
        proxy_pass http://lucee_PROJECT_NAME_PLACEHOLDER;
        expires -1;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
    }
}
NGINXEOF

            # Replace placeholders with actual values
            sed -i "s/PROJECT_NAME_PLACEHOLDER/$PROJECT_NAME/g" "$NGINX_CONFIG"
            sed -i "s/PROJECT_PORT_PLACEHOLDER/$PROJECT_PORT/g" "$NGINX_CONFIG"  
            sed -i "s/PROJECT_DOMAIN_PLACEHOLDER/$PROJECT_DOMAIN/g" "$NGINX_CONFIG"
          done
          
          echo ""
          echo "Nginx configuration generated:"
          echo "  Main config: $OUTPUT_DIR/nginx.conf"
          echo "  Site configs: $OUTPUT_DIR/sites/"
          echo ""
          echo "Start nginx with: bash $OUTPUT_DIR/start-nginx.sh"
          
          # Generate start script for nginx
          cat > "$OUTPUT_DIR/start-nginx.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

NGINX_DIR="$OUTPUT_DIR"
NGINX_CONF="\$NGINX_DIR/nginx.conf"

# Test configuration
echo "Testing nginx configuration..."
${pkgs.nginx}/bin/nginx -t -c "\$NGINX_CONF"

# Check if nginx is already running
if [[ -f /tmp/nginx.pid ]] && kill -0 "\$(cat /tmp/nginx.pid)" 2>/dev/null; then
    echo "Nginx already running. Reloading configuration..."
    ${pkgs.nginx}/bin/nginx -s reload
else
    echo "Starting nginx on port 8080..."
    ${pkgs.nginx}/bin/nginx -c "\$NGINX_CONF"
fi

echo "Nginx ready! Available projects:"
${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | "  http://" + .value.domain + ":8080 -> localhost:" + (.value.port | tostring)' "$REGISTRY_FILE"
EOF
          
          chmod +x "$OUTPUT_DIR/start-nginx.sh"
          
          # Generate stop script
          cat > "$OUTPUT_DIR/stop-nginx.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /tmp/nginx.pid ]]; then
    echo "Stopping nginx..."
    ${pkgs.nginx}/bin/nginx -s quit
    echo "Nginx stopped."
else
    echo "Nginx not running."
fi
EOF
          
          chmod +x "$OUTPUT_DIR/stop-nginx.sh"
        '';

        # Tomcat config updater - updates server.xml with assigned port
        tomcatConfigUpdater = pkgs.writeShellScriptBin "lucee-update-tomcat-config" ''
          set -euo pipefail
          
          PROJECT_PATH="$1"
          HTTP_PORT="$2"
          SHUTDOWN_PORT=$((HTTP_PORT + 1000))
          
          SERVER_XML="$PROJECT_PATH/lucee-instance/conf/server.xml"
          
          if [[ ! -f "$SERVER_XML" ]]; then
            echo "Error: server.xml not found at $SERVER_XML"
            exit 1
          fi
          
          echo "Updating Tomcat configuration at $SERVER_XML"
          echo "  HTTP Port: $HTTP_PORT"
          echo "  Shutdown Port: $SHUTDOWN_PORT"
          
          # Backup original file
          cp "$SERVER_XML" "$SERVER_XML.backup"
          
          # Update the HTTP connector port and shutdown port using sed
          ${pkgs.gnused}/bin/sed -i "s/port=\"[0-9]*\" shutdown/port=\"$SHUTDOWN_PORT\" shutdown/g" "$SERVER_XML"
          ${pkgs.gnused}/bin/sed -i "s/Connector port=\"[0-9]*\"/Connector port=\"$HTTP_PORT\"/g" "$SERVER_XML"
          
          echo "Tomcat configuration updated successfully"
        '';

        # Project starter - comprehensive start command
        projectStarter = pkgs.writeShellScriptBin "lucee-start-project" ''
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
          
          # Step 6: Start the Lucee project
          echo "Step 6: Starting Lucee instance..."
          echo "  Changing to project directory: $PROJECT_PATH"
          cd "$PROJECT_PATH"
          
          echo "  Running: nix run ."
          echo "  The Lucee instance will start shortly..."
          echo ""
          
          # Get project info for final message
          DOMAIN=$(${pkgs.jq}/bin/jq -r --arg name "$PROJECT_NAME" '.projects[$name].domain' "$REGISTRY_FILE")
          
          echo "==================== Lucee Project Starting ===================="
          echo "Project: $PROJECT_NAME"
          echo "Port: $PORT"
          echo "Domain: $DOMAIN"
          echo "Direct access: http://localhost:$PORT"
          echo "Proxy access: http://$DOMAIN:8080"
          echo ""
          echo "To check status: lucee-manager list"
          echo "To stop: press Ctrl+C (then run: lucee-manager track $PROJECT_NAME stopped)"
          echo "=============================================================="
          echo ""
          
          # Start with nix run and update status when ready
          {
            nix run . &
            NIX_PID=$!
            
            # Wait for the service to be ready and update status
            echo "Waiting for Lucee to start..."
            for i in {1..30}; do
              if ${pkgs.nettools}/bin/netstat -tuln 2>/dev/null | grep -q ":$PORT "; then
                echo "Lucee is ready!"
                lucee-track-port "$PROJECT_NAME" "running" "$REGISTRY_FILE"
                break
              fi
              sleep 2
            done
            
            # Wait for the nix process to finish
            wait $NIX_PID
            
            # Update status when process ends
            lucee-track-port "$PROJECT_NAME" "stopped" "$REGISTRY_FILE"
          }
        '';

        # Main CLI interface
        luceeManager = pkgs.writeShellScriptBin "lucee-manager" ''
          set -euo pipefail
          
          # Add our tools to PATH
          export PATH="${projectScanner}/bin:${portAllocator}/bin:${portTracker}/bin:${nginxGenerator}/bin:${tomcatConfigUpdater}/bin:${projectStarter}/bin:$PATH"
          
          COMMAND="''${1:-help}"
          REGISTRY_FILE="$HOME/.lucee-manager/registry.json"
          
          case "$COMMAND" in
            scan|discover)
              PROJECTS_DIR="''${2:-$PWD}"
              echo "Scanning for Lucee projects..."
              lucee-scan "$PROJECTS_DIR" "$REGISTRY_FILE"
              ;;
              
            list|ls|status)
              if [[ ! -f "$REGISTRY_FILE" ]]; then
                echo "No projects found. Run 'lucee-manager scan' first."
                exit 1
              fi
              
              echo "Lucee Projects (managed by reverse proxy):"
              echo "=========================================="
              ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | 
                "  \(.key):" + 
                "\n    Port: \(.value.port // "not assigned")" + 
                "\n    Status: \(.value.status // "unknown")" + 
                "\n    Domain: \(.value.domain)" + 
                "\n    Path: \(.value.path)" + 
                (if .value.port then "\n    Direct: http://localhost:\(.value.port)" else "" end) +
                (if .value.port then "\n    Proxy: http://\(.value.domain):8080" else "" end) +
                "\n"' "$REGISTRY_FILE"
              ;;
              
            assign-port)
              PROJECT_NAME="''${2:-}"
              if [[ -z "$PROJECT_NAME" ]]; then
                echo "Usage: lucee-manager assign-port <project-name>"
                exit 1
              fi
              
              PORT=$(lucee-port-allocate "$PROJECT_NAME" "$REGISTRY_FILE")
              echo "Assigned port $PORT to project '$PROJECT_NAME'"
              echo "Start your Lucee project manually, then run: lucee-manager track $PROJECT_NAME running"
              ;;
              
            track)
              PROJECT_NAME="''${2:-}"
              STATUS="''${3:-running}"
              if [[ -z "$PROJECT_NAME" ]]; then
                echo "Usage: lucee-manager track <project-name> [running|stopped]"
                exit 1
              fi
              
              lucee-track-port "$PROJECT_NAME" "$STATUS" "$REGISTRY_FILE"
              echo "Updated status for '$PROJECT_NAME' to '$STATUS'"
              ;;
              
            nginx)
              NGINX_COMMAND="''${2:-generate}"
              case "$NGINX_COMMAND" in
                generate|gen)
                  lucee-nginx-generate "$REGISTRY_FILE" "$HOME/.lucee-manager/nginx"
                  ;;
                start)
                  if [[ ! -f "$HOME/.lucee-manager/nginx/start-nginx.sh" ]]; then
                    echo "Nginx config not found. Run 'lucee-manager nginx generate' first."
                    exit 1
                  fi
                  bash "$HOME/.lucee-manager/nginx/start-nginx.sh"
                  ;;
                stop)
                  bash "$HOME/.lucee-manager/nginx/stop-nginx.sh"
                  ;;
                reload)
                  if [[ -f /tmp/nginx.pid ]]; then
                    echo "Reloading nginx configuration..."
                    ${pkgs.nginx}/bin/nginx -s reload
                    echo "Nginx reloaded."
                  else
                    echo "Nginx not running. Start with 'lucee-manager nginx start'"
                  fi
                  ;;
                *)
                  echo "Usage: lucee-manager nginx {generate|start|stop|reload}"
                  exit 1
                  ;;
               esac
               ;;
               
             start)
               PROJECT_NAME="''${2:-}"
               if [[ -z "$PROJECT_NAME" ]]; then
                 echo "Usage: lucee-manager start <project-name>"
                 exit 1
               fi
               
               lucee-start-project "$PROJECT_NAME" "$REGISTRY_FILE"
               ;;
               
             help|--help|-h)
              cat <<EOF
Lucee Reverse Proxy Manager

Automatically manages nginx reverse proxy for multiple Lucee instances.

Usage:
  lucee-manager <command> [options]

Project Discovery:
  scan [directory]         Scan directory for Lucee projects (default: current dir)
  list                     List all discovered projects and their status
  
Port Management:
  assign-port <project>    Assign an available port to a project
  track <project> <status> Update project status (running|stopped)
  
Project Management:
  start <project>          Complete startup: assign port, update config, start nginx, run project
  
Nginx Reverse Proxy:
  nginx generate           Generate nginx configuration for all projects
  nginx start              Start nginx reverse proxy on port 8080
  nginx stop               Stop nginx reverse proxy
  nginx reload             Reload nginx configuration
  
Simple Workflow (Recommended):
  1. lucee-manager scan ~/projects     # Discover Lucee projects
  2. lucee-manager start myapp         # One command to start everything!

Manual Workflow:
  1. lucee-manager scan ~/projects     # Discover Lucee projects
  2. lucee-manager assign-port myapp   # Get port assignment
  3. Start your Lucee project manually on assigned port
  4. lucee-manager track myapp running # Mark as running
  5. lucee-manager nginx generate      # Generate reverse proxy config
  6. lucee-manager nginx start         # Start reverse proxy

Examples:
  # Simple workflow (recommended)
  lucee-manager scan ~/code                    # Discover projects
  lucee-manager start my-cms-project           # Start everything with one command
  
  # Manual workflow  
  lucee-manager scan ~/code
  lucee-manager assign-port my-cms-project  
  lucee-manager nginx generate
  lucee-manager nginx start

Access projects via: http://project-name.local:8080
Direct access via: http://localhost:PORT

Registry: $REGISTRY_FILE
EOF
              ;;
              
            *)
              echo "Unknown command: $COMMAND"
              echo "Run 'lucee-manager help' for usage information."
              exit 1
              ;;
          esac
        '';

      in
      {
        # Packages
        packages = {
          default = luceeManager;
          lucee-manager = luceeManager;
          lucee-scan = projectScanner;
          lucee-port-allocate = portAllocator; 
          lucee-track-port = portTracker;
          lucee-nginx-generate = nginxGenerator;
          lucee-update-tomcat-config = tomcatConfigUpdater;
          lucee-start-project = projectStarter;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            jq
            nginx
            nettools  # for ss command
            # All our tools
            luceeManager
            projectScanner
            portAllocator
            portTracker
            nginxGenerator
          ];

          shellHook = ''
            echo "Lucee Reverse Proxy Manager"
            echo "=========================="
            echo ""
            echo "This tool manages nginx reverse proxy for multiple Lucee instances."
            echo ""
            echo "Quick start:"
            echo "  lucee-manager scan          - Find Lucee projects"
            echo "  lucee-manager assign-port   - Get port assignments"  
            echo "  lucee-manager nginx start   - Start reverse proxy"
            echo ""
            echo "Run 'lucee-manager help' for full documentation"
            echo ""
          '';
        };
      }
    );
}