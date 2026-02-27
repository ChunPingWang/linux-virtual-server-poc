#!/bin/bash
VIP="192.168.100.100"
echo "============================================"
echo " Basic LVS Connectivity Test"
echo " VIP: ${VIP}"
echo "============================================"

echo ""
echo "── Test 1: VIP Reachability ──"
ping -c 3 -W 2 ${VIP} && echo "  ✅ VIP is reachable" || echo "  ❌ VIP unreachable"

echo ""
echo "── Test 2: HTTP Response ──"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://${VIP}/ 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✅ HTTP 200 OK"
else
    echo "  ❌ HTTP response: ${HTTP_CODE}"
fi

echo ""
echo "── Test 3: Server Identity (10 requests) ──"
for i in $(seq 1 10); do
    RESPONSE=$(curl -s http://${VIP}/api/info.json 2>/dev/null)
    SERVER=$(echo "$RESPONSE" | jq -r '.server // "unknown"' 2>/dev/null)
    echo "  Request ${i}: Served by ${SERVER}"
done

echo ""
echo "============================================"
