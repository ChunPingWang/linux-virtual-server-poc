#!/bin/bash
# ============================================================================
# Test Client Provisioning Script
# Installs: curl, ab (Apache Bench), wrk, hping3
# Provides: test scripts for LVS PoC validation
# ============================================================================
set -euo pipefail

echo "============================================"
echo " Provisioning Test Client"
echo "============================================"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl apache2-utils net-tools hping3 tcpdump jq > /dev/null 2>&1

VIP="192.168.100.100"

# ──────────────────────────────────────────────
# 1. Basic connectivity test
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-basic.sh << 'TEST_EOF'
#!/bin/bash
VIP="192.168.100.100"
echo "============================================"
echo " Basic LVS Connectivity Test"
echo " VIP: ${VIP}"
echo "============================================"

echo ""
echo "── Test 1: VIP Reachability ──"
ping -c 3 -W 2 ${VIP} && echo "✅ VIP is reachable" || echo "❌ VIP unreachable"

echo ""
echo "── Test 2: HTTP Response ──"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://${VIP}/ 2>/dev/null)
if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ HTTP 200 OK"
else
    echo "❌ HTTP response: ${HTTP_CODE}"
fi

echo ""
echo "── Test 3: Server Identity ──"
for i in $(seq 1 10); do
    RESPONSE=$(curl -s http://${VIP}/api/info.json 2>/dev/null)
    SERVER=$(echo "$RESPONSE" | jq -r '.server // "unknown"' 2>/dev/null)
    echo "  Request ${i}: Served by ${SERVER}"
done

echo ""
echo "============================================"
TEST_EOF
chmod +x /usr/local/bin/test-basic.sh

# ──────────────────────────────────────────────
# 2. Load distribution test
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-distribution.sh << 'TEST_EOF'
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
echo "  Expected ratio (wrr weights 3:2:1):"
echo "    real-server-1 : ~50%"
echo "    real-server-2 : ~33%"
echo "    real-server-3 : ~17%"
echo "============================================"
TEST_EOF
chmod +x /usr/local/bin/test-distribution.sh

# ──────────────────────────────────────────────
# 3. Failover test
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-failover.sh << 'TEST_EOF'
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
echo "   2. In another terminal, SSH to lvs-director-1:"
echo "      vagrant ssh lvs-director-1"
echo "   3. Simulate failure:"
echo "      sudo systemctl stop keepalived"
echo "   4. Watch VIP failover to director-2"
echo "   5. Restore:"
echo "      sudo systemctl start keepalived"
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
TEST_EOF
chmod +x /usr/local/bin/test-failover.sh

# ──────────────────────────────────────────────
# 4. Performance / Load test
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-performance.sh << 'TEST_EOF'
#!/bin/bash
VIP="192.168.100.100"
CONCURRENCY=${1:-10}
TOTAL_REQUESTS=${2:-1000}
echo "============================================"
echo " Performance Test (Apache Bench)"
echo " VIP: ${VIP}"
echo " Concurrency: ${CONCURRENCY}"
echo " Total Requests: ${TOTAL_REQUESTS}"
echo "============================================"

echo ""
echo "── Running ab test ──"
ab -n ${TOTAL_REQUESTS} -c ${CONCURRENCY} -H "Connection: close" http://${VIP}/ 2>&1 | \
    grep -E "(Requests per second|Time per request|Transfer rate|Failed|Complete|Connect:|Processing:|Waiting:|Total:)"

echo ""
echo "============================================"
TEST_EOF
chmod +x /usr/local/bin/test-performance.sh

# ──────────────────────────────────────────────
# 5. DSR Verification (packet capture)
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-dsr-verify.sh << 'TEST_EOF'
#!/bin/bash
VIP="192.168.100.100"
echo "============================================"
echo " DSR (Direct Server Return) Verification"
echo " VIP: ${VIP}"
echo "============================================"
echo ""
echo " This captures packets to verify DSR behavior:"
echo "   - Request:  Client -> Director (VIP) -> Real Server"
echo "   - Response: Real Server -> Client (bypasses Director)"
echo ""
echo "── Capturing 20 packets on port 80 ──"
echo " (Run 'test-basic.sh' in another terminal to generate traffic)"
echo ""

SVC_IFACE=$(ip -4 route show to 192.168.100.0/24 | awk '{print $3; exit}')
SVC_IFACE=${SVC_IFACE:-eth1}

timeout 30 tcpdump -i ${SVC_IFACE} -n -c 20 "tcp port 80" 2>/dev/null | while read line; do
    if echo "$line" | grep -q "192.168.100.50.*${VIP}"; then
        echo "  📤 REQUEST  (Client → VIP): $line"
    elif echo "$line" | grep -q "192.168.100.2[0-9].*192.168.100.50"; then
        echo "  📥 DSR RESPONSE (RealServer → Client directly): $line"
    elif echo "$line" | grep -q "${VIP}.*192.168.100.50"; then
        echo "  ⚠️  VIP RESPONSE (NOT DSR - going through Director): $line"
    else
        echo "  ── $line"
    fi
done

echo ""
echo "── Capture Complete ──"
echo " In DSR mode, you should see responses coming directly"
echo " from Real Server IPs (192.168.100.2x), NOT from VIP."
echo "============================================"
TEST_EOF
chmod +x /usr/local/bin/test-dsr-verify.sh

# ──────────────────────────────────────────────
# 6. Full test suite runner
# ──────────────────────────────────────────────
cat > /usr/local/bin/test-all.sh << 'TEST_EOF'
#!/bin/bash
echo "╔════════════════════════════════════════════╗"
echo "║   LVS PoC - Full Test Suite                ║"
echo "╚════════════════════════════════════════════╝"
echo ""

echo "▶ Phase 1: Basic Connectivity"
echo "──────────────────────────────"
test-basic.sh
echo ""

echo "▶ Phase 2: Load Distribution (50 requests)"
echo "──────────────────────────────"
test-distribution.sh 50
echo ""

echo "▶ Phase 3: Performance (500 req, 10 concurrent)"
echo "──────────────────────────────"
test-performance.sh 10 500
echo ""

echo "╔════════════════════════════════════════════╗"
echo "║   All Tests Complete                        ║"
echo "║                                              ║"
echo "║   Additional manual tests:                   ║"
echo "║   • test-failover.sh    (HA failover)       ║"
echo "║   • test-dsr-verify.sh  (DSR packet trace)  ║"
echo "╚════════════════════════════════════════════╝"
TEST_EOF
chmod +x /usr/local/bin/test-all.sh

echo ""
echo "✅ Client provisioned successfully!"
echo ""
echo "   Available test scripts:"
echo "   ─────────────────────────────────────"
echo "   test-all.sh             Full test suite"
echo "   test-basic.sh           Basic connectivity"
echo "   test-distribution.sh N  Load distribution (N requests)"
echo "   test-failover.sh N      Failover monitor (N seconds)"
echo "   test-performance.sh C N Performance test"
echo "   test-dsr-verify.sh      DSR packet verification"
echo "   ─────────────────────────────────────"
