# Nginx configuration generator
{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-nginx-generate" ''
  set -euo pipefail
  
  if [[ ! -f "${conf.reg.path}" ]]; then
    echo "Registry not found. Run 'lucee-scan' first."
    exit 1
  fi
  
  mkdir -p "${conf.nginx}/sites"
  mkdir -p "${conf.logs}"

  echo "Generating nginx configuration for Lucee reverse proxy..."

  # Read nginx port from registry, default to 8080 if not set
  NGINX_PORT=$(${pkgs.jq}/bin/jq -r '.nginxPort // 8080' "${conf.reg.path}")

  NEEDS_SUDO=""
  if [[ $NGINX_PORT -lt 1024 && $EUID -ne 0 ]]; then
    NEEDS_SUDO="sudo"
    echo "⚠️  Port $NGINX_PORT requires root privileges. You may be prompted for your password."
  fi

  cp -f --no-preserve=mode ${./templates/nginx/nginx.conf} ${conf.nginx}/nginx.conf

  ${pkgs.gnused}/bin/sed -i "s|LOGS_DIR|${conf.logs}|g" ${conf.nginx}/nginx.conf

  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | 
    "  -> \(.key) (\(.value.domain) -> localhost:\(.value.port))"' "${conf.reg.path}"

  TEMP_PROJECTS=$(mktemp)
  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | @base64' "${conf.reg.path}" > "$TEMP_PROJECTS"

  while read -r project_b64; do
    project_data=$(echo "$project_b64" | base64 -d)
    project_name=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.key')
    project_domain=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.domain')
    project_port=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.port')
    project_template=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.nginxTemplate // empty')
    
    # Use custom template if available in registry, otherwise use default
    if [[ -n "$project_template" && -f "$project_template" ]]; then
      echo "  -> Using custom template for $project_name: $project_template"
      TEMPLATE_PATH="$project_template"
    else
      TEMPLATE_PATH="${../scripts/templates/nginx/server.conf}"
      if [[ -n "$project_template" ]]; then
        echo "  -> Warning: Custom template not found for $project_name: $project_template"
        echo "  -> Falling back to default template"
      fi
    fi
    
    # Generate server configuration from template
    cp -f --no-preserve=mode "$TEMPLATE_PATH" "${conf.nginx}/sites/$project_name.conf"
    
    # Replace placeholders
    ${pkgs.gnused}/bin/sed -i \
      -e "s/SERVERNAME/$project_domain/g" \
      -e "s/LUCEE_PORT/$project_port/g" \
      -e "s/NGINX_PORT/$NGINX_PORT/g" \
      -e "s/listen [0-9]*;/listen $NGINX_PORT;/g" \
      "${conf.nginx}/sites/$project_name.conf"
  done < "$TEMP_PROJECTS"

  rm "$TEMP_PROJECTS"

  # Generate start script
  cat > "${conf.nginx}/start-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f "${conf.logs}/nginx.pid" ]] && ps -p \$(cat "${conf.logs}/nginx.pid") > /dev/null; then
      echo "Nginx is already running (PID: \$(cat "${conf.logs}/nginx.pid"))"
      exit 0
    fi

    echo "Starting nginx reverse proxy on port $NGINX_PORT..."
    $NEEDS_SUDO ${pkgs.nginx}/bin/nginx -c "${conf.nginx}/nginx.conf"

    if [[ -f "${conf.logs}/nginx.pid" ]]; then
      echo "Nginx started successfully (PID: \$(cat "${conf.logs}/nginx.pid"))"
      echo "Access your projects via: http://project-domain:$NGINX_PORT"
    else
      echo "Failed to start nginx"
      exit 1
    fi
  EOF

  chmod +x "${conf.nginx}/start-nginx.sh"

  # Generate stop script
  cat > "${conf.nginx}/stop-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f "${conf.logs}/nginx.pid" ]]; then
        echo "Stopping nginx..."
        $NEEDS_SUDO ${pkgs.nginx}/bin/nginx -s quit -c "${conf.nginx}/nginx.conf"
        echo "Nginx stopped."
    else
        echo "Nginx not running."
    fi
  EOF

  chmod +x "${conf.nginx}/stop-nginx.sh"

  echo ""
  echo "Nginx configuration generated:"
  echo "  Main config: ${conf.nginx}/nginx.conf"
  echo "  Site configs: ${conf.nginx}/sites/"
  echo "  Port: $NGINX_PORT $(if [[ -n "$NEEDS_SUDO" ]]; then echo "(requires sudo)"; fi)"
  echo ""
  echo "Start nginx with: bash ${conf.nginx}/start-nginx.sh"
''
