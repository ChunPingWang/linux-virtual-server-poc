#!/bin/bash
set -euo pipefail

echo "============================================"
echo " LVS Director: ${HOSTNAME}"
echo " Role: ${KEEPALIVED_ROLE} | Priority: ${KEEPALIVED_PRIORITY}"
echo " VIP: ${VIP}"
echo "============================================"

# ──────────────────────────────────────────────
# Detect service interface
# ──────────────────────────────────────────────
SVC_IFACE=$(ip -4 route show to 192.168.100.0/24 | awk '{print $3; exit}')
if [ -z "$SVC_IFACE" ]; then
  SVC_IFACE="eth0"
fi
echo "Service interface detected: ${SVC_IFACE}"

# ──────────────────────────────────────────────
# Build Keepalived config
# ──────────────────────────────────────────────
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

mkdir -p /etc/keepalived

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
    persistence_timeout 0
    protocol TCP

    sorry_server 127.0.0.1 8080

${RS_BLOCKS}
}
KEEPALIVED_EOF

# ──────────────────────────────────────────────
# Notify script
# ──────────────────────────────────────────────
cat > /usr/local/bin/lvs-notify.sh << 'NOTIFY_EOF'
#!/bin/bash
STATE="$1"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[${TIMESTAMP}] Keepalived state changed to: ${STATE}" >> /var/log/lvs-state.log
echo "[${TIMESTAMP}] Keepalived state changed to: ${STATE}"
NOTIFY_EOF
chmod +x /usr/local/bin/lvs-notify.sh

# ──────────────────────────────────────────────
# Sorry server (fallback when all RS down)
# ──────────────────────────────────────────────
mkdir -p /var/www/sorry
cat > /var/www/sorry/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html><body>
<h1>Service Temporarily Unavailable</h1>
<p>All backend servers are currently down. Please try again later.</p>
</body></html>
HTML_EOF

# Start sorry server in background
cd /var/www/sorry && python3 -m http.server 8080 &

# ──────────────────────────────────────────────
# Status script
# ──────────────────────────────────────────────
cat > /usr/local/bin/lvs-status.sh << 'STATUS_EOF'
#!/bin/bash
echo "============================================"
echo " LVS Director Status: $(hostname)"
echo " Timestamp: $(date)"
echo "============================================"
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
echo "============================================"
STATUS_EOF
chmod +x /usr/local/bin/lvs-status.sh

# ──────────────────────────────────────────────
# Create health flag and start Keepalived
# ──────────────────────────────────────────────
touch /var/run/keepalived_healthy

echo ""
echo "Starting Keepalived..."
# Run keepalived in foreground (container main process)
exec keepalived --dont-fork --log-console --log-detail --dump-conf
