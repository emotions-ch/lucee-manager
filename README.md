Lucee Reverse Proxy Manager CLI

Automatically manages nginx reverse proxy for multiple Lucee dev instances created using [lucee-nix](https://github.com/emotions-ch/lucee-nix/blob/main/examples/devshell.nix).

# instance Configuration

## lucee-manager.json

Each Lucee project can optionally include a `lucee-instance/conf/lucee-manager.json` file to customize its configuration. This file is read during project scanning and the settings are stored in the registry, so if any changes are made you will have to scan the project again.

| Field | Type | Description | Example | Default |
|-------|------|-------------|---------|---------|
| `project` | String | Project name used in registry and commands | `"my-cms-project"` | Directory name |
| `domain` | String | Custom domain for nginx reverse proxy | `"myapp.local"` | `"<project>.local"` |
| `nginx.templateFile` | String | Alternative nested field for nginx template path | `"/absolute/path/to/template.conf"` | Uses default template |

### Configuration Examples

**Basic Configuration:**
```json
{
  "project": "my-cms-project",
  "domain": "mycms.devlocal.example.com"
}
```
**With Custom Template:**
```json
{
  "project": "my-cms-project",
  "domain": "mycms.devlocal.example.com", 
  "nginx": {
    "templateFile": "/nix/store/path/to/template.conf"
  }
}
```

### Custom Nginx Templates

Custom nginx templates support placeholder substitution:
- `SERVERNAME` → Replaced with the project's domain
- `LUCEE_PORT` → Replaced with the assigned port number

# CLI-Usage
`lucee-manager <command> [options]`

## Project Discovery
| Command | Description |
|---------|-------------|
| `scan [directory]` | Scan directory for Lucee projects (default: current dir) |
| `list` | List all discovered projects and their status |

## Port Management
| Command | Description |
|---------|-------------|
| `assign-port <project>` | Assign an available port to a project |
| `track <project> <status>` | Update project status (running\|stopped) |

## Project Management
| Command | Description |
|---------|-------------|
| `start <project>` | Complete startup: assign port, update config, start nginx, run project |
| `stop <project>` | Stop running project and update status |

## Nginx Reverse Proxy
| Command | Description |
|---------|-------------|
| `nginx generate` | Generate nginx configuration for all projects |
| `nginx start` | Start nginx reverse proxy on port 8080 |
| `nginx stop` | Stop nginx reverse proxy |
| `nginx reload` | Reload nginx configuration |

# Simple workflow (recommended)
1. `lucee-manager scan ~/code`
2. `lucee-manager start my-cms-project`
3. `lucee-manager stop my-cms-project`

# Manual workflow
1. `lucee-manager scan ~/code`
2. `lucee-manager assign-port my-cms-project`
3. `lucee-manager nginx generate`
4. `lucee-manager nginx start`

# Files
_you shouldnt need to touch any of these but who knows_
- Logs: `~/.lucee-manager/logs`
- Nginx: `~/.lucee-manager/nginx`
- Registry: `~/.lucee-manager/registry.json`

