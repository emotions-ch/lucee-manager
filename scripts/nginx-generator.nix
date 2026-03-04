# Nginx configuration generator
{ pkgs }:

pkgs.writeShellScriptBin "lucee-nginx-generate" ''
  set -euo pipefail
  
  REGISTRY_FILE="''${1:-$HOME/.lucee-manager/registry.json}"
  OUTPUT_DIR="''${2:-$HOME/.lucee-manager/nginx}"
  
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "Registry not found. Run 'lucee-scan' first."
    exit 1
  fi
  
  mkdir -p "$OUTPUT_DIR/sites"
  
  echo "Generating nginx configuration for Lucee reverse proxy..."
  
  # Generate main nginx.conf
  cat > "$OUTPUT_DIR/nginx.conf" <<'EOF'
worker_processes auto;
pid /tmp/nginx.pid;
error_log /tmp/nginx_error.log;

events {
    worker_connections 1024;
}

http {
    # Basic MIME types
    types {
        text/html                             html htm shtml;
        text/css                              css;
        text/xml                              xml;
        image/gif                             gif;
        image/jpeg                            jpeg jpg;
        application/javascript                js;
        application/atom+xml                  atom;
        application/rss+xml                   rss;
        text/mathml                           mml;
        text/plain                            txt;
        text/vnd.sun.j2me.app-descriptor      jad;
        text/vnd.wap.wml                      wml;
        text/x-component                      htc;
        image/png                             png;
        image/tiff                            tif tiff;
        image/vnd.wap.wbmp                    wbmp;
        image/x-icon                          ico;
        image/x-jng                           jng;
        image/x-ms-bmp                        bmp;
        image/svg+xml                         svg svgz;
        image/webp                            webp;
        application/font-woff                 woff;
        application/java-archive              jar war ear;
        application/json                      json;
        application/mac-binhex40              hqx;
        application/msword                    doc;
        application/pdf                       pdf;
        application/postscript                ps eps ai;
        application/rtf                       rtf;
        application/vnd.apple.mpegurl         m3u8;
        application/vnd.ms-excel              xls;
        application/vnd.ms-fontobject         eot;
        application/vnd.ms-powerpoint         ppt;
        application/vnd.wap.wmlc              wmlc;
        application/vnd.google-earth.kml+xml  kml;
        application/vnd.google-earth.kmz      kmz;
        application/x-7z-compressed           7z;
        application/x-cocoa                   cco;
        application/x-java-archive-diff       jardiff;
        application/x-java-jnlp-file          jnlp;
        application/x-makeself                run;
        application/x-perl                    pl pm;
        application/x-pilot                   prc pdb;
        application/x-rar-compressed          rar;
        application/x-redhat-package-manager  rpm;
        application/x-sea                     sea;
        application/x-shockwave-flash         swf;
        application/x-stuffit                 sit;
        application/x-tcl                     tcl tk;
        application/x-x509-ca-cert            der pem crt;
        application/x-xpinstall               xpi;
        application/xhtml+xml                 xhtml;
        application/xspf+xml                  xspf;
        application/zip                       zip;
        application/octet-stream              bin exe dll;
        application/octet-stream              deb;
        application/octet-stream              dmg;
        application/octet-stream              iso img;
        application/octet-stream              msi msp msm;
        audio/midi                            mid midi kar;
        audio/mpeg                            mp3;
        audio/ogg                             ogg;
        audio/x-m4a                           m4a;
        audio/x-realaudio                     ra;
        video/3gpp                            3gpp 3gp;
        video/mp2t                            ts;
        video/mp4                             mp4;
        video/mpeg                            mpeg mpg;
        video/quicktime                       mov;
        video/webm                            webm;
        video/x-flv                           flv;
        video/x-m4v                           m4v;
        video/x-mng                           mng;
        video/x-ms-asf                        asx asf;
        video/x-ms-wmv                        wmv;
        video/x-msvideo                       avi;
    }

    default_type application/octet-stream;
    
    # Logging
    access_log /tmp/nginx_access.log;
    
    # Basic settings optimized for CFML
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 128;  # Support for long domain names
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml;

    # Include site configurations
    include sites/*.conf;
}
EOF

  # Generate individual site configurations
  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | 
    "  -> \(.key) (\(.value.domain) -> localhost:\(.value.port))"' "$REGISTRY_FILE"

  ${pkgs.jq}/bin/jq -r '.projects | to_entries[] | select(.value.port != null) | @base64' "$REGISTRY_FILE" | while read -r project_b64; do
    project_data=$(echo "$project_b64" | base64 -d)
    project_name=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.key')
    project_domain=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.domain')
    project_port=$(echo "$project_data" | ${pkgs.jq}/bin/jq -r '.value.port')
    
    cat > "$OUTPUT_DIR/sites/$project_name.conf" <<EOF
server {
    listen 8080;
    server_name $project_domain;
    
    # CFML-specific settings
    client_max_body_size 100m;
    proxy_read_timeout 300;
    proxy_connect_timeout 30;
    proxy_send_timeout 300;
    
    location / {
        proxy_pass http://127.0.0.1:$project_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Handle WebSocket upgrades
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Caching for static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            proxy_pass http://127.0.0.1:$project_port;
            proxy_set_header Host \$host;
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF
  done
  
  # Generate start script
  cat > "$OUTPUT_DIR/start-nginx.sh" <<EOF
#!/bin/bash
if [[ -f /tmp/nginx.pid ]]; then
    echo "Nginx is already running (PID: \$(cat /tmp/nginx.pid))"
    exit 0
fi

echo "Starting nginx reverse proxy on port 8080..."
${pkgs.nginx}/bin/nginx -c "$OUTPUT_DIR/nginx.conf"

if [[ -f /tmp/nginx.pid ]]; then
    echo "Nginx started successfully (PID: \$(cat /tmp/nginx.pid))"
    echo "Access your projects via: http://project-domain:8080"
else
    echo "Failed to start nginx"
    exit 1
fi
EOF
  
  chmod +x "$OUTPUT_DIR/start-nginx.sh"
  
  # Generate stop script
  cat > "$OUTPUT_DIR/stop-nginx.sh" <<EOF
#!/bin/bash
if [[ -f /tmp/nginx.pid ]]; then
    echo "Stopping nginx..."
    ${pkgs.nginx}/bin/nginx -s quit
    echo "Nginx stopped."
else
    echo "Nginx not running."
fi
EOF
  
  chmod +x "$OUTPUT_DIR/stop-nginx.sh"
  
  echo ""
  echo "Nginx configuration generated:"
  echo "  Main config: $OUTPUT_DIR/nginx.conf"
  echo "  Site configs: $OUTPUT_DIR/sites/"
  echo ""
  echo "Start nginx with: bash $OUTPUT_DIR/start-nginx.sh"
''