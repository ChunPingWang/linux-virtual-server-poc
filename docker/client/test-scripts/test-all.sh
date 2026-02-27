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
