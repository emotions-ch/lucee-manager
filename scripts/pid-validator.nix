{ pkgs, conf }:

pkgs.writeShellScriptBin "lucee-pid-validate" ''
  set -euo pipefail

  REGISTRY_FILE="${conf.reg.path}"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    exit 0
  fi

  TEMP_REGISTRY=$(mktemp)
  cp "$REGISTRY_FILE" "$TEMP_REGISTRY"

  PROJECTS=$(${pkgs.lib.getExe pkgs.jq} -r '.projects | to_entries[] | select(.value.status == "running" and .value.pid) | .key + " " + (.value.pid|tostring)' "$REGISTRY_FILE")

  echo "$PROJECTS" | while read -r project pid; do
    if ! ps -p "$pid" > /dev/null; then
      echo "Stale PID found for project '$project'. Updating status..."
      ${pkgs.lib.getExe pkgs.jq} --arg project "$project" '
        .projects[$project].status = "stopped" |
        del(.projects[$project].pid)
      ' "$TEMP_REGISTRY" > "$TEMP_REGISTRY.tmp" && mv "$TEMP_REGISTRY.tmp" "$TEMP_REGISTRY"
    fi
  done

  mv "$TEMP_REGISTRY" "$REGISTRY_FILE"
''
