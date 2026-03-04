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
  stop <project>           Stop running project and update status
  
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
  lucee-manager stop my-cms-project            # Stop the project cleanly
  
  # Manual workflow  
  lucee-manager scan ~/code
  lucee-manager assign-port my-cms-project  
  lucee-manager nginx generate
  lucee-manager nginx start

Access projects via: http://project-name.local:8080
Direct access via: http://localhost:PORT

Registry: ~/.lucee-manager/registry.json
