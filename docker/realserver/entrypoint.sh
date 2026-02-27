#!/bin/bash
set -euo pipefail

echo "============================================"
echo " Real Server: ${RS_NAME}"
echo " IP: ${RS_IP} | VIP: ${VIP}"
echo "============================================"

# ──────────────────────────────────────────────
# DSR Configuration - ARP Suppression
# ──────────────────────────────────────────────
echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
echo 2 > /proc/sys/net/ipv4/conf/all/arp_announce
echo 1 > /proc/sys/net/ipv4/conf/lo/arp_ignore
echo 2 > /proc/sys/net/ipv4/conf/lo/arp_announce

echo "ARP suppression configured (arp_ignore=1, arp_announce=2)"

# ──────────────────────────────────────────────
# Configure VIP on loopback
# ──────────────────────────────────────────────
ip addr add ${VIP}/32 dev lo label lo:0 2>/dev/null || true
echo "VIP ${VIP}/32 added to lo:0"

# ──────────────────────────────────────────────
# Configure Nginx content
# ──────────────────────────────────────────────
cat > /usr/share/nginx/html/index.html << HTML_EOF
<!DOCTYPE html>
<html>
<head><title>LVS PoC - ${RS_NAME}</title></head>
<body>
<h1>Hello from ${RS_NAME}</h1>
<table border="1" cellpadding="8">
  <tr><td><b>Server</b></td><td>${RS_NAME}</td></tr>
  <tr><td><b>Real IP</b></td><td>${RS_IP}</td></tr>
  <tr><td><b>VIP</b></td><td>${VIP}</td></tr>
  <tr><td><b>Timestamp</b></td><td><span id="ts"></span></td></tr>
</table>
<script>document.getElementById('ts').textContent = new Date().toISOString();</script>
</body>
</html>
HTML_EOF

# Health check endpoint
echo "OK" > /usr/share/nginx/html/health

# API JSON endpoint
mkdir -p /usr/share/nginx/html/api
cat > /usr/share/nginx/html/api/info.json << JSON_EOF
{
  "server": "${RS_NAME}",
  "ip": "${RS_IP}",
  "vip": "${VIP}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "uptime": "$(cat /proc/uptime | awk '{print $1}')"
}
JSON_EOF

# Nginx config
cat > /etc/nginx/conf.d/default.conf << NGINX_EOF
server {
    listen 80 default_server;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    location /api/ {
        add_header Content-Type application/json;
        add_header X-Served-By ${RS_NAME};
    }

    location / {
        add_header X-Served-By ${RS_NAME};
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF

# Status script
cat > /usr/local/bin/rs-status.sh << 'STATUS_EOF'
#!/bin/bash
echo "============================================"
echo " Real Server Status: $(hostname)"
echo "============================================"
echo ""
echo "── VIP on Loopback ──"
ip addr show lo | grep "192.168.100.100" && echo "  VIP bound to lo" || echo "  VIP NOT on lo"
echo ""
echo "── ARP Settings ──"
echo "  arp_ignore  (all): $(cat /proc/sys/net/ipv4/conf/all/arp_ignore)"
echo "  arp_announce (all): $(cat /proc/sys/net/ipv4/conf/all/arp_announce)"
echo ""
echo "── Nginx Status ──"
curl -s http://localhost/health && echo "  Health check: OK" || echo "  Health check: FAILED"
echo "============================================"
STATUS_EOF
chmod +x /usr/local/bin/rs-status.sh

echo ""
echo "Starting Nginx..."
exec nginx -g "daemon off;"
