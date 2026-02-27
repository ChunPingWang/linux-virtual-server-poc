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
