{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-interactive" ''
  set -euo pipefail

  if [[ ! -f "${conf.reg.path}" ]]; then
    echo "No projects found. Run 'lucee-manager scan' first."
    exit 1
  fi

  # Command selection
  COMMAND=$(${pkgs.lib.getExe pkgs.fzf} --prompt="Select a command" <<EOF
  scan
  list
  start
  stop
  assign-port
  track
  nginx
  EOF
  )

  if [ "$COMMAND" == "nginx" ]; then
    NGINX_COMMAND=$(${pkgs.lib.getExe pkgs.fzf} --prompt="Select an nginx command" <<EOF
      generate
      start
      stop
      reload
  EOF
  )
  echo $NGINX_COMMAND
    lucee-manager nginx $NGINX_COMMAND
  else
    PROJECT_COMMANDS=("start" "stop" "assign-port" "track")
    if [[ " ''${PROJECT_COMMANDS[@]} " =~ " ''${COMMAND} " ]]; then
      PROJECT_NAME=$(${pkgs.lib.getExe pkgs.jq} -r '.projects | keys[]' "${conf.reg.path}" | ${pkgs.lib.getExe pkgs.fzf} --prompt="Select a project")
      lucee-manager "$COMMAND" "$PROJECT_NAME"
    else
      lucee-manager "$COMMAND"
    fi
  fi
''
