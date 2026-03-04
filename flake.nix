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

        # Import all our scripts
        projectScanner = import ./scripts/project-scanner.nix { inherit pkgs; };
        portAllocator = import ./scripts/port-allocator.nix { inherit pkgs; };
        portTracker = import ./scripts/port-tracker.nix { inherit pkgs; };
        nginxGenerator = import ./scripts/nginx-generator.nix { inherit pkgs; };
        tomcatConfigUpdater = import ./scripts/tomcat-config-updater.nix { inherit pkgs; };
        projectStarter = import ./scripts/project-starter.nix { inherit pkgs; };
        projectStopper = import ./scripts/project-stopper.nix { inherit pkgs; };
        
        # Main CLI tool that imports all other scripts
        luceeManager = pkgs.writeShellScriptBin "lucee-manager" ''
          set -euo pipefail
          
          # Add our tools to PATH
          export PATH="${pkgs.lib.makeBinPath [
            projectScanner
            portAllocator
            portTracker
            nginxGenerator
            tomcatConfigUpdater
            projectStarter
            projectStopper
          ]}:$PATH"
          
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
                (if .value.pid then "\n    PID: \(.value.pid)" else "" end) +
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
                     ${pkgs.nginx}/bin/nginx -s reload -c "$HOME/.lucee-manager/nginx/nginx.conf"
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
              
            stop)
              PROJECT_NAME="''${2:-}"
              if [[ -z "$PROJECT_NAME" ]]; then
                echo "Usage: lucee-manager stop <project-name>"
                exit 1
              fi
              
              lucee-stop-project "$PROJECT_NAME" "$REGISTRY_FILE"
              ;;
              
            help|--help|-h)
              cat ${./README.md}
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
          lucee-stop-project = projectStopper;
        };

        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            jq
            nginx
            iproute2  # for ss command
            procps    # for ps, pgrep commands
            nettools  # for netstat (fallback)
            gnused    # for sed
            gnugrep   # for grep
            coreutils # for kill
            # All our tools
            luceeManager
            projectScanner
            portAllocator
            portTracker
            nginxGenerator
            tomcatConfigUpdater
            projectStarter
            projectStopper
          ];

          shellHook = ''
            echo "Lucee Reverse Proxy Manager"
            echo "=========================="
            echo "Available commands:"
            echo "  lucee-manager help"
            echo "  lucee-manager scan"
            echo "  lucee-manager start <project>"
            echo ""
          '';
        };
      }
    );
}
