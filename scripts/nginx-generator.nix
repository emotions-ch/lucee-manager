# Nginx configuration generator
{ pkgs }:

pkgs.writeShellScriptBin "lucee-nginx-generate" ''
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
  cp -f --no-preserve=mode ${./templates/nginx/nginx.conf} $OUTPUT_DIR/nginx.conf

  # Generate individual site configurations
  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | 
    "  -> \(.key) (\(.value.domain) -> localhost:\(.value.port))"' "$REGISTRY_FILE"

  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | @base64' "$REGISTRY_FILE" | while read -r project_b64; do
    project_data=$(echo "$project_b64" | base64 -d)
    project_name=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.key')
    project_domain=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.domain')
    project_port=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.port')
    project_path=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.path')
    
    # Check for custom template in project's lucee-manager.json
    TEMPLATE_PATH="${../scripts/templates/nginx/server.conf}"  # default template
    CONFIG_FILE="$project_path/lucee-instance/conf/lucee-manager.json"
    
    if [[ -f "$CONFIG_FILE" ]]; then
      CUSTOM_TEMPLATE=$(${pkgs.jq}/bin/jq -r '.template // .nginx.templateFile // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
      if [[ -n "$CUSTOM_TEMPLATE" ]]; then
        if [[ "$CUSTOM_TEMPLATE" =~ ^/ ]]; then
          CUSTOM_TEMPLATE_PATH="$CUSTOM_TEMPLATE"
        else
          CUSTOM_TEMPLATE_PATH="$project_path/$CUSTOM_TEMPLATE"
        fi
        
        if [[ -f "$CUSTOM_TEMPLATE_PATH" ]]; then
          echo "  -> Using custom template for $project_name: $CUSTOM_TEMPLATE"
          TEMPLATE_PATH="$CUSTOM_TEMPLATE_PATH"
        else
          echo "  -> Warning: Custom template not found for $project_name: $CUSTOM_TEMPLATE_PATH"
          echo "  -> Falling back to default template"
        fi
      fi
    fi
    
    # Generate server configuration from template
    cp -f --no-preserve=mode "$TEMPLATE_PATH" "$OUTPUT_DIR/sites/$project_name.conf"
    
    # Replace placeholders
    ${pkgs.gnused}/bin/sed -i \
      -e "s/SERVERNAME/$project_domain/g" \
      -e "s/LUCEE_PORT/$project_port/g" \
      "$OUTPUT_DIR/sites/$project_name.conf"
  done
  
  # Generate start script
  cat > "$OUTPUT_DIR/start-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f /tmp/nginx.pid ]]; then
      echo "Nginx is already running (PID: \$(cat /tmp/nginx.pid))"
      exit 0
    fi

    echo "Starting nginx reverse proxy on port 8080..."
    ${pkgs.nginx}/bin/nginx -c "$OUTPUT_DIR/nginx.conf"

    if [[ -f /tmp/nginx.pid ]]; then
      echo "Nginx started successfully (PID: \$(cat /tmp/nginx.pid))"
      echo "Access your projects via: http://project-domain:8080"
    else
      echo "Failed to start nginx"
      exit 1
    fi
  EOF

  chmod +x "$OUTPUT_DIR/start-nginx.sh"

  # Generate stop script
  cat > "$OUTPUT_DIR/stop-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f /tmp/nginx.pid ]]; then
        echo "Stopping nginx..."
        ${pkgs.nginx}/bin/nginx -s quit -c "$OUTPUT_DIR/nginx.conf"
        echo "Nginx stopped."
    else
        echo "Nginx not running."
    fi
  EOF

  chmod +x "$OUTPUT_DIR/stop-nginx.sh"

  echo ""
  echo "Nginx configuration generated:"
  echo "  Main config: $OUTPUT_DIR/nginx.conf"
  echo "  Site configs: $OUTPUT_DIR/sites/"
  echo ""
  echo "Start nginx with: bash $OUTPUT_DIR/start-nginx.sh"
''
