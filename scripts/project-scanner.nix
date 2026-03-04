# Project scanner - discovers Lucee projects in a directory
{ pkgs }:

pkgs.writeShellScriptBin "lucee-scan" ''
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
        TEMPLATE_PATH=$(${pkgs.jq}/bin/jq -r '.nginx.templateFile // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        
        if [[ -n "$CONFIGURED_NAME" ]]; then
          echo "  -> Using configured project name: $CONFIGURED_NAME"
          project_name="$CONFIGURED_NAME"
        fi
        
        if [[ -n "$CONFIGURED_DOMAIN" ]]; then
          echo "  -> Using configured domain: $CONFIGURED_DOMAIN"
          PROJECT_DOMAIN="$CONFIGURED_DOMAIN"
        else
          PROJECT_DOMAIN="$project_name.local"
        fi

        if [[ -n "$TEMPLATE_PATH" ]]; then
          echo "  -> Found nginx template: $TEMPLATE_PATH"
          # Handle absolute paths directly, relative paths are relative to project directory
          if [[ "$TEMPLATE_PATH" =~ ^/ ]]; then
            NGINX_TEMPLATE="$TEMPLATE_PATH"
          else
            NGINX_TEMPLATE="$(realpath "$project_dir/$TEMPLATE_PATH")"
          fi

          if [[ -f "$NGINX_TEMPLATE" ]]; then
            echo "  -> Nginx template verified: $NGINX_TEMPLATE"
          else
            echo "  -> Warning: Nginx template not found: $NGINX_TEMPLATE"
            NGINX_TEMPLATE=""
          fi
        fi
      else
        echo "  -> No lucee-manager.json found, using defaults"
        PROJECT_DOMAIN="$project_name.local"
      fi
      
      ABSOLUTE_PATH=$(realpath "$project_dir")
      
      CURRENT_STATUS=$(${pkgs.jq}/bin/jq -r --arg name "$project_name" '.projects[$name].status // "stopped"' "$REGISTRY_FILE" 2>/dev/null || echo "stopped")
      if [[ "$CURRENT_STATUS" == "running" ]]; then
        echo "  -> Project is currently running, stopping before registry update..."
        lucee-stop-project "$project_name" "$REGISTRY_FILE" || {
          echo "  -> Warning: Failed to stop project, continuing with registry update"
        }
      fi

      # Add/update project in registry
      ${pkgs.jq}/bin/jq --arg name "$project_name" \
                        --arg path "$ABSOLUTE_PATH" \
                        --arg domain "$PROJECT_DOMAIN" \
                        --arg timestamp "$(date -Iseconds)" \
                        --arg template "$NGINX_TEMPLATE" \
                        '.projects[$name] = {
                          path: $path,
                          discovered: $timestamp,
                          domain: $domain
                        } | 
                        (if $template != "" then .projects[$name].nginxTemplate = $template else . end) |
                        .projects[$name] = (.projects[$name] + {status: (.projects[$name].status // "stopped")}) | 
                        .lastScan = $timestamp' \
                        "$REGISTRY_FILE" > "$REGISTRY_FILE.tmp"
      
      mv "$REGISTRY_FILE.tmp" "$REGISTRY_FILE"
      echo "  -> Added to registry as: $project_name"
    fi
  done
  
  echo ""
  echo "Scan complete. Found projects:"
  ${pkgs.jq}/bin/jq -r '.projects | keys[]' "$REGISTRY_FILE"
''
