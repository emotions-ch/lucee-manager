{ pkgs, lib }:

{
  # Helper functions for Lucee reverse proxy management
  
  # Generate consistent port from project name using hash
  hashToPort = projectName: rangeStart: rangeSize:
    let
      hash = builtins.hashString "sha256" projectName;
      # Simple hash-based port assignment - use string length and content
      hashValue = builtins.stringLength hash + builtins.stringLength projectName;
      # Simple modulo implementation
      mod = x: m: x - (m * (x / m));
    in
      rangeStart + (mod hashValue rangeSize);
  
  # Validate project directory structure
  isLuceeProject = projectPath:
    let
      flakeExists = builtins.pathExists (projectPath + "/flake.nix");
      wwwrootExists = builtins.pathExists (projectPath + "/wwwroot");
    in
      flakeExists && wwwrootExists;
  
  # Port range management
  defaultPortRange = {
    start = 8100;
    end = 8199;
  };
  
  # Common paths
  getRegistryPath = "$HOME/.lucee-manager/registry.json";
  getNginxPath = "$HOME/.lucee-manager/nginx";
}