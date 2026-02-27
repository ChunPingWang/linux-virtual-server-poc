#!/bin/bash
VIP="192.168.100.100"
DURATION=${1:-30}
echo "============================================"
echo " Failover Monitoring (${DURATION} seconds)"
echo " VIP: ${VIP}"
echo "============================================"
echo ""
echo " Instructions:"
echo "   1. Start this script"
echo "   2. In another terminal:"
echo "      docker exec lvs-director-1 rm -f /var/run/keepalived_healthy"
echo "      (or: docker stop lvs-director-1)"
echo "   3. Watch VIP failover to director-2"
echo "   4. Restore:"
echo "      docker exec lvs-director-1 touch /var/run/keepalived_healthy"
echo "      (or: docker start lvs-director-1)"
echo ""
echo "── Monitoring Started ──"

for i in $(seq 1 ${DURATION}); do
    TIMESTAMP=$(date '+%H:%M:%S')
    RESPONSE=$(curl -s --connect-timeout 1 --max-time 2 http://${VIP}/api/info.json 2>/dev/null)
    if [ -n "$RESPONSE" ]; then
        SERVER=$(echo "$RESPONSE" | jq -r '.server // "?"' 2>/dev/null)
        printf "  [%s] ✅ VIP responding - Served by: %s\n" "$TIMESTAMP" "$SERVER"
    else
        printf "  [%s] ❌ VIP NOT responding (failover in progress?)\n" "$TIMESTAMP"
    fi
    sleep 1
done

echo ""
echo "── Monitoring Complete ──"
echo "============================================"
