# Nginx configuration generator
{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-nginx-generate" ''
  set -euo pipefail
  
  if [[ ! -f "${conf.reg.path}" ]]; then
    echo "Registry not found. Run 'lucee-scan' first."
    exit 1
  fi
  
  mkdir -p "${conf.nginx}/sites"
  
  echo "Generating nginx configuration for Lucee reverse proxy..."
  
  cp -f --no-preserve=mode ${./templates/nginx/nginx.conf} ${conf.nginx}/nginx.conf

  # Generate individual site configurations
  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | 
    "  -> \(.key) (\(.value.domain) -> localhost:\(.value.port))"' "${conf.reg.path}"

  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | @base64' "${conf.reg.path}" | while read -r project_b64; do
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
      "${conf.nginx}/sites/$project_name.conf"
  done
  
  # Generate start script
  cat > "${conf.nginx}/start-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f /tmp/nginx.pid ]] && ps -p $(cat /tmp/nginx.pid) > /dev/null; then
      echo "Nginx is already running (PID: \$(cat /tmp/nginx.pid))"
      exit 0
    fi

    echo "Starting nginx reverse proxy on port 8080..."
    ${pkgs.nginx}/bin/nginx -c "${conf.nginx}/nginx.conf"

    if [[ -f /tmp/nginx.pid ]]; then
      echo "Nginx started successfully (PID: \$(cat /tmp/nginx.pid))"
      echo "Access your projects via: http://project-domain:8080"
    else
      echo "Failed to start nginx"
      exit 1
    fi
  EOF

  chmod +x "${conf.nginx}/start-nginx.sh"

  # Generate stop script
  cat > "${conf.nginx}/stop-nginx.sh" <<EOF
    #!/bin/bash
    if [[ -f /tmp/nginx.pid ]]; then
        echo "Stopping nginx..."
        ${pkgs.nginx}/bin/nginx -s quit -c "${conf.nginx}/nginx.conf"
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
  echo ""
  echo "Start nginx with: bash ${conf.nginx}/start-nginx.sh"
''
