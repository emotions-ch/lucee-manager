Lucee Reverse Proxy Manager CLI

Automatically manages nginx reverse proxy for multiple Lucee dev instances created using [lucee-nix](https://github.com/emotions-ch/lucee-nix/blob/main/examples/devshell.nix).

# Usage
`lucee-manager <command> [options]`

## Project Discovery
`scan [directory]`         Scan directory for Lucee projects (default: current dir)
`list`                     List all discovered projects and their status

## Port Management
`assign-port <project>`    Assign an available port to a project
`track <project> <status>` Update project status (running|stopped)

## Project Management
`start <project>`          Complete startup: assign port, update config, start nginx, run project
`stop <project>`           Stop running project and update status

## Nginx Reverse Proxy
`nginx generate`           Generate nginx configuration for all projects
`nginx start`              Start nginx reverse proxy on port 8080
`nginx stop`               Stop nginx reverse proxy
`nginx reload`             Reload nginx configuration

# Simple workflow (recommended)
- `lucee-manager scan ~/code`                   # Discover projects
- `lucee-manager start my-cms-project`          # Start everything with one command
- `lucee-manager stop my-cms-project`           # Stop the project cleanly

# Manual workflow
- `lucee-manager scan ~/code`
- `lucee-manager assign-port my-cms-project`
- `lucee-manager nginx generate`
- `lucee-manager nginx start`

# Files
_you shouldnt need to touch any of these but who knows_
- Logs: `~/.lucee-manager/logs`
- Nginx: `~/.lucee-manager/nginx`
- Registry: `~/.lucee-manager/registry.json`
