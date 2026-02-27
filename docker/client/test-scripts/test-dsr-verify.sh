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
echo " (Sending test traffic in background...)"
echo ""

SVC_IFACE=$(ip -4 route show to 192.168.100.0/24 | awk '{print $3; exit}')
SVC_IFACE=${SVC_IFACE:-eth0}

# Generate traffic in background
(sleep 2; for i in $(seq 1 10); do curl -s -o /dev/null http://${VIP}/ 2>/dev/null; sleep 0.5; done) &

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
