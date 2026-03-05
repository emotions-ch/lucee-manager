# Tomcat config updater - updates server.xml with assigned port
{ pkgs }:

pkgs.writeShellScriptBin "lucee-update-tomcat-config" ''
  set -euo pipefail
  
  PROJECT_PATH="$1"
  HTTP_PORT="$2"
  SHUTDOWN_PORT=$((HTTP_PORT + 1000))
  
  SERVER_XML="$PROJECT_PATH/lucee-instance/conf/server.xml"
  
  if [[ ! -f "$SERVER_XML" ]]; then
    echo "Error: server.xml not found at $SERVER_XML"
    exit 1
  fi
  
  echo "Updating Tomcat configuration at $SERVER_XML"
  echo "  HTTP Port: $HTTP_PORT"
  echo "  Shutdown Port: $SHUTDOWN_PORT"
  
  # Backup original file
  cp "$SERVER_XML" "$SERVER_XML.backup"
  
  # Update the shutdown port in the Server element
  ${pkgs.gnused}/bin/sed -i "s/<Server port=\"[0-9]*\"/<Server port=\"$SHUTDOWN_PORT\"/g" "$SERVER_XML"
  
  # Update the HTTP connector port (looking for port="NNNN" in Connector elements)
  ${pkgs.gnused}/bin/sed -i "s/port=\"[0-9]*\" protocol=\"HTTP\/1\.1\"/port=\"$HTTP_PORT\" protocol=\"HTTP\/1.1\"/g" "$SERVER_XML"
  
  echo "Verification:"
  echo "  Server shutdown port: $(${pkgs.gnugrep}/bin/grep -o '<Server port="[0-9]*"' "$SERVER_XML" || echo "Not found")"
  echo "  HTTP connector port: $(${pkgs.gnugrep}/bin/grep -o 'port="[0-9]*" protocol="HTTP/1\.1"' "$SERVER_XML" || echo "Not found")"
''
