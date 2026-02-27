#!/bin/bash
# ============================================================================
# LVS Director Provisioning Script
# Installs: ipvsadm, keepalived
# Configures: IPVS DR (DSR) mode + Keepalived VRRP failover
# ============================================================================
set -euo pipefail

DIRECTOR_IP="$1"
KEEPALIVED_ROLE="$2"     # MASTER or BACKUP
KEEPALIVED_PRIORITY="$3" # 100 for MASTER, 90 for BACKUP
VIP="$4"
REAL_SERVERS_CSV="$5"    # "ip:weight,ip:weight,..."

echo "============================================"
echo " Provisioning LVS Director: ${HOSTNAME}"
echo " Role: ${KEEPALIVED_ROLE} | Priority: ${KEEPALIVED_PRIORITY}"
echo " VIP: ${VIP}"
echo "============================================"

# ──────────────────────────────────────────────
# 1. System packages
# ──────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ipvsadm keepalived net-tools curl jq > /dev/null 2>&1

# ──────────────────────────────────────────────
# 2. Enable IP forwarding
# ──────────────────────────────────────────────
cat > /etc/sysctl.d/99-lvs.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.vs.conntrack = 1
EOF
sysctl --system > /dev/null 2>&1

# ──────────────────────────────────────────────
# 3. Build Keepalived config
# ──────────────────────────────────────────────

# Detect the private network interface (not eth0/vagrant default)
SVC_IFACE=$(ip -4 route show to 192.168.100.0/24 | awk '{print $3; exit}')
if [ -z "$SVC_IFACE" ]; then
  SVC_IFACE="eth1"
fi

echo "Service interface detected: ${SVC_IFACE}"

# Build real_server blocks for keepalived
RS_BLOCKS=""
IFS=',' read -ra RS_ARRAY <<< "$REAL_SERVERS_CSV"
for rs_entry in "${RS_ARRAY[@]}"; do
  RS_IP="${rs_entry%%:*}"
  RS_WEIGHT="${rs_entry##*:}"
  RS_BLOCKS+="
    real_server ${RS_IP} 80 {
        weight ${RS_WEIGHT}
        inhibit_on_failure

        HTTP_GET {
            url {
                path /health
                status_code 200
            }
            connect_timeout 3
            retry 3
            delay_before_retry 2
        }
    }
"
done

cat > /etc/keepalived/keepalived.conf << KEEPALIVED_EOF
! ============================================
! Keepalived Configuration - ${HOSTNAME}
! Role: ${KEEPALIVED_ROLE}
! ============================================

global_defs {
    router_id ${HOSTNAME}
    enable_script_security
    script_user root
}

! ──────────────────────────────────────────
! VRRP Health Check Script
! ──────────────────────────────────────────
vrrp_script chk_ipvs {
    script "/usr/bin/test -f /var/run/keepalived_healthy"
    interval 2
    weight 2
    fall 3
    rise 2
}

! ──────────────────────────────────────────
! VRRP Instance - VIP Failover
! ──────────────────────────────────────────
vrrp_instance LVS_VIP {
    state ${KEEPALIVED_ROLE}
    interface ${SVC_IFACE}
    virtual_router_id 51
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass LvsP0c2024
    }

    virtual_ipaddress {
        ${VIP}/32 dev ${SVC_IFACE}
    }

    track_script {
        chk_ipvs
    }

    ! Notify scripts for logging
    notify_master "/usr/local/bin/lvs-notify.sh MASTER"
    notify_backup "/usr/local/bin/lvs-notify.sh BACKUP"
    notify_fault  "/usr/local/bin/lvs-notify.sh FAULT"
}

! ──────────────────────────────────────────
! Virtual Server - DSR (DR) Mode
! ──────────────────────────────────────────
virtual_server ${VIP} 80 {
    delay_loop 6
    lb_algo wrr
    lb_kind DR
    persistence_timeout 60
    protocol TCP

    sorry_server 127.0.0.1 8080

${RS_BLOCKS}
}
KEEPALIVED_EOF

# ──────────────────────────────────────────────
# 4. Notify script (for logging state changes)
# ──────────────────────────────────────────────
cat > /usr/local/bin/lvs-notify.sh << 'NOTIFY_EOF'
#!/bin/bash
STATE="$1"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[${TIMESTAMP}] Keepalived state changed to: ${STATE}" >> /var/log/lvs-state.log
logger -t keepalived "State changed to ${STATE}"
NOTIFY_EOF
chmod +x /usr/local/bin/lvs-notify.sh

# ──────────────────────────────────────────────
# 5. Sorry server (fallback when all RS down)
# ──────────────────────────────────────────────
mkdir -p /var/www/sorry
cat > /var/www/sorry/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html><body>
<h1>Service Temporarily Unavailable</h1>
<p>All backend servers are currently down. Please try again later.</p>
</body></html>
HTML_EOF

# Simple Python HTTP sorry server as systemd service
cat > /etc/systemd/system/sorry-server.service << 'SVC_EOF'
[Unit]
Description=LVS Sorry Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/sorry
ExecStart=/usr/bin/python3 -m http.server 8080
Restart=always

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable sorry-server --now > /dev/null 2>&1

# ──────────────────────────────────────────────
# 6. Monitoring script
# ──────────────────────────────────────────────
cat > /usr/local/bin/lvs-status.sh << 'STATUS_EOF'
#!/bin/bash
echo "============================================"
echo " LVS Director Status: $(hostname)"
echo " Timestamp: $(date)"
echo "============================================"

echo ""
echo "── Keepalived Status ──"
systemctl is-active keepalived && echo "  Keepalived: RUNNING" || echo "  Keepalived: STOPPED"

echo ""
echo "── VIP Status ──"
ip addr show | grep -q "192.168.100.100" && echo "  VIP: ACTIVE on this node" || echo "  VIP: NOT on this node"

echo ""
echo "── IPVS Table ──"
ipvsadm -Ln --stats 2>/dev/null || echo "  (no IPVS entries)"

echo ""
echo "── Connection Stats ──"
ipvsadm -Ln --rate 2>/dev/null || echo "  (no rate data)"

echo ""
echo "── Recent State Changes ──"
tail -5 /var/log/lvs-state.log 2>/dev/null || echo "  (no state log)"

echo ""
echo "============================================"
STATUS_EOF
chmod +x /usr/local/bin/lvs-status.sh

# ──────────────────────────────────────────────
# 7. Create health flag and start Keepalived
# ──────────────────────────────────────────────
touch /var/run/keepalived_healthy

systemctl enable keepalived --now
systemctl restart keepalived

echo ""
echo "✅ Director ${HOSTNAME} provisioned successfully!"
echo "   Role     : ${KEEPALIVED_ROLE}"
echo "   Priority : ${KEEPALIVED_PRIORITY}"
echo "   VIP      : ${VIP}"
echo "   Run: lvs-status.sh to check status"
