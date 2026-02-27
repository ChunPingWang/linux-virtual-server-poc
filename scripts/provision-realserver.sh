#!/bin/bash
# ============================================================================
# Real Server Provisioning Script
# Installs: Nginx
# Configures: DSR loopback (VIP on lo), ARP suppression
# ============================================================================
set -euo pipefail

RS_IP="$1"
RS_NAME="$2"
VIP="$3"

echo "============================================"
echo " Provisioning Real Server: ${RS_NAME}"
echo " IP: ${RS_IP} | VIP: ${VIP}"
echo "============================================"

# ──────────────────────────────────────────────
# 1. System packages
# ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx net-tools curl jq > /dev/null 2>&1

# ──────────────────────────────────────────────
# 2. DSR Configuration - ARP Suppression
# ──────────────────────────────────────────────
# In DR (DSR) mode, the Real Server must:
#   a) Have the VIP configured on loopback (to accept packets destined for VIP)
#   b) NOT respond to ARP requests for the VIP (only the Director should)
#   c) NOT announce the VIP via ARP
# ──────────────────────────────────────────────

cat > /etc/sysctl.d/99-lvs-dsr.conf << EOF
# ── LVS DSR: ARP Suppression ──
# Prevent Real Server from responding to ARP for VIP
# arp_ignore=1  : Reply only if target IP is local address on incoming interface
# arp_announce=2: Use best local address as source in ARP request

net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.lo.arp_ignore = 1
net.ipv4.conf.lo.arp_announce = 2
EOF

sysctl --system > /dev/null 2>&1

# ──────────────────────────────────────────────
# 3. Configure VIP on loopback interface
# ──────────────────────────────────────────────
# Add VIP as a /32 on lo so the kernel accepts packets for VIP
# Use a label (lo:0) for easy identification

# Persistent via netplan (Ubuntu 22.04)
cat > /etc/netplan/60-lvs-vip.yaml << EOF
network:
  version: 2
  ethernets:
    lo:
      addresses:
        - ${VIP}/32
EOF

chmod 600 /etc/netplan/60-lvs-vip.yaml
netplan apply 2>/dev/null || true

# Also apply immediately in case netplan doesn't handle lo well
ip addr add ${VIP}/32 dev lo label lo:0 2>/dev/null || true

# ──────────────────────────────────────────────
# 4. Configure Nginx
# ──────────────────────────────────────────────

# Main site - responds with server identity for testing
cat > /var/www/html/index.html << HTML_EOF
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
mkdir -p /var/www/html
cat > /var/www/html/health << 'HTML_EOF'
OK
HTML_EOF

# API-style JSON endpoint for testing
cat > /usr/local/bin/generate-api-response.sh << SCRIPT_EOF
#!/bin/bash
cat > /var/www/html/api/info.json << JSON_EOF
{
  "server": "${RS_NAME}",
  "ip": "${RS_IP}",
  "vip": "${VIP}",
  "timestamp": "\$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "load": \$(awk '{print \$1}' /proc/loadavg),
  "connections": \$(ss -s | grep estab | awk '{print \$2}' | head -1)
}
JSON_EOF
SCRIPT_EOF
chmod +x /usr/local/bin/generate-api-response.sh

mkdir -p /var/www/html/api
/usr/local/bin/generate-api-response.sh

# Cron to refresh API response every 10 seconds
cat > /etc/cron.d/lvs-api << 'CRON_EOF'
* * * * * root for i in $(seq 0 10 50); do sleep $i; /usr/local/bin/generate-api-response.sh; done
CRON_EOF

# Nginx config - listen on both Real IP and VIP
cat > /etc/nginx/sites-available/default << NGINX_EOF
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    # Health check endpoint for Keepalived
    location /health {
        access_log off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }

    # API info endpoint
    location /api/ {
        add_header Content-Type application/json;
        add_header X-Served-By ${RS_NAME};
    }

    # Default
    location / {
        add_header X-Served-By ${RS_NAME};
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF

# ──────────────────────────────────────────────
# 5. Start Nginx
# ──────────────────────────────────────────────
nginx -t 2>/dev/null
systemctl enable nginx --now
systemctl reload nginx

# ──────────────────────────────────────────────
# 6. Verification script
# ──────────────────────────────────────────────
cat > /usr/local/bin/rs-status.sh << 'STATUS_EOF'
#!/bin/bash
echo "============================================"
echo " Real Server Status: $(hostname)"
echo " Timestamp: $(date)"
echo "============================================"

echo ""
echo "── VIP on Loopback ──"
ip addr show lo | grep "192.168.100.100" && echo "  ✅ VIP bound to lo" || echo "  ❌ VIP NOT on lo"

echo ""
echo "── ARP Settings ──"
echo "  arp_ignore  (all): $(cat /proc/sys/net/ipv4/conf/all/arp_ignore)"
echo "  arp_announce (all): $(cat /proc/sys/net/ipv4/conf/all/arp_announce)"

echo ""
echo "── Nginx Status ──"
systemctl is-active nginx && echo "  ✅ Nginx: RUNNING" || echo "  ❌ Nginx: STOPPED"
curl -s http://localhost/health && echo "  ✅ Health check: OK" || echo "  ❌ Health check: FAILED"

echo ""
echo "── Active Connections ──"
ss -tnp | grep ":80" | wc -l | xargs -I{} echo "  Connections on port 80: {}"

echo ""
echo "============================================"
STATUS_EOF
chmod +x /usr/local/bin/rs-status.sh

echo ""
echo "✅ Real Server ${RS_NAME} provisioned successfully!"
echo "   IP  : ${RS_IP}"
echo "   VIP : ${VIP} (on lo:0)"
echo "   ARP : Suppressed (arp_ignore=1, arp_announce=2)"
echo "   Run : rs-status.sh to check status"
