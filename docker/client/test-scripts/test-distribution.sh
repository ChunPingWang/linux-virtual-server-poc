#!/bin/bash
VIP="192.168.100.100"
REQUESTS=${1:-100}
echo "============================================"
echo " Load Distribution Test (${REQUESTS} requests)"
echo " VIP: ${VIP}"
echo "============================================"

declare -A SERVER_COUNT

for i in $(seq 1 ${REQUESTS}); do
    SERVER=$(curl -s -H "Connection: close" http://${VIP}/api/info.json 2>/dev/null | jq -r '.server // "unknown"' 2>/dev/null)
    if [ -n "$SERVER" ]; then
        SERVER_COUNT[$SERVER]=$(( ${SERVER_COUNT[$SERVER]:-0} + 1 ))
    fi
done

echo ""
echo "── Distribution Results ──"
TOTAL=0
for server in "${!SERVER_COUNT[@]}"; do
    COUNT=${SERVER_COUNT[$server]}
    TOTAL=$((TOTAL + COUNT))
done

for server in $(echo "${!SERVER_COUNT[@]}" | tr ' ' '\n' | sort); do
    COUNT=${SERVER_COUNT[$server]}
    PCT=$(echo "scale=1; ${COUNT} * 100 / ${TOTAL}" | bc 2>/dev/null || echo "N/A")
    BAR=$(printf '%0.s█' $(seq 1 $((COUNT * 50 / TOTAL))) 2>/dev/null)
    printf "  %-16s : %4d requests (%5s%%) %s\n" "$server" "$COUNT" "$PCT" "$BAR"
done

echo ""
echo "  Total successful: ${TOTAL} / ${REQUESTS}"
echo ""
echo "  Expected ratio (wrr weights 3:2):"
echo "    real-server-1 : ~60%  (weight 3)"
echo "    real-server-2 : ~40%  (weight 2)"
echo "============================================"
