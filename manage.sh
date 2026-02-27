#!/bin/bash
# ============================================================================
# LVS PoC Cluster Management Script (Docker Mode)
# Usage: ./manage.sh [command]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    cat << 'EOF'
╔════════════════════════════════════════════════╗
║   LVS PoC Cluster Management (Docker)         ║
╚════════════════════════════════════════════════╝

Usage: ./manage.sh [command]

Commands:
  up          Start all containers (docker compose up)
  down        Stop all containers
  destroy     Destroy all containers and images
  status      Show cluster status
  test        Run test suite from client
  exec NODE   Exec shell into a specific container
  failover    Simulate director failover
  recover     Recover from failover
  ipvs        Show IPVS table on active director
  logs        Show keepalived logs

Containers: lvs-director-1, lvs-director-2,
            real-server-1, real-server-2, lvs-client

Examples:
  ./manage.sh up                       # Start cluster
  ./manage.sh exec lvs-director-1      # Shell into director
  ./manage.sh test                     # Run tests
  ./manage.sh failover                 # Simulate HA failover
EOF
}

cmd_up() {
    echo "🚀 Starting LVS PoC Cluster (Docker)..."
    echo ""
    echo "Building and starting: Directors → Real Servers → Client"
    echo ""

    docker compose up -d --build

    echo ""
    echo "✅ Cluster is up! Waiting 10s for Keepalived to stabilize..."
    sleep 10

    cmd_status
}

cmd_down() {
    echo "🛑 Stopping LVS PoC Cluster..."
    docker compose down
    echo "✅ All containers stopped."
}

cmd_destroy() {
    echo "⚠️  This will destroy ALL containers and images. Are you sure? (y/N)"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker compose down --rmi all --volumes --remove-orphans
        echo "✅ All containers and images destroyed."
    else
        echo "Cancelled."
    fi
}

cmd_status() {
    echo "╔════════════════════════════════════════════════╗"
    echo "║   LVS PoC Cluster Status                      ║"
    echo "╚════════════════════════════════════════════════╝"
    echo ""

    echo "── Container Status ──"
    docker compose ps
    echo ""

    echo "── Director-1 IPVS Table ──"
    docker exec lvs-director-1 ipvsadm -Ln 2>/dev/null || echo "  (unreachable)"
    echo ""

    echo "── VIP Location ──"
    for dir in lvs-director-1 lvs-director-2; do
        HAS_VIP=$(docker exec ${dir} ip addr show 2>/dev/null | grep -c '192.168.100.100' || echo "0")
        if [ "$HAS_VIP" -gt 0 ] 2>/dev/null; then
            echo "  ✅ VIP is on: ${dir}"
        fi
    done
    echo ""

    echo "── Real Server Health ──"
    for rs in real-server-1 real-server-2; do
        HEALTH=$(docker exec ${rs} curl -s http://localhost/health 2>/dev/null | tr -d '[:space:]')
        RS_IP=$(docker exec ${rs} hostname -I 2>/dev/null | awk '{print $1}' | tr -d '[:space:]')
        if [ "$HEALTH" = "OK" ]; then
            echo "  ✅ ${rs} (${RS_IP}): Healthy"
        else
            echo "  ❌ ${rs}: Unhealthy"
        fi
    done
    echo ""
}

cmd_test() {
    echo "🧪 Running test suite from client..."
    docker exec lvs-client test-all.sh
}

cmd_exec() {
    NODE="${1:-}"
    if [ -z "$NODE" ]; then
        echo "Usage: ./manage.sh exec <container-name>"
        echo "Containers: lvs-director-1, lvs-director-2, real-server-{1,2}, lvs-client"
        exit 1
    fi
    docker exec -it "$NODE" bash
}

cmd_failover() {
    echo "🔄 Simulating Director Failover..."
    echo ""
    echo "── Before failover ──"
    for dir in lvs-director-1 lvs-director-2; do
        HAS_VIP=$(docker exec ${dir} ip addr show 2>/dev/null | grep -c '192.168.100.100' || echo "0")
        if [ "$HAS_VIP" -gt 0 ] 2>/dev/null; then
            echo "  VIP is currently on: ${dir}"
        fi
    done

    echo ""
    echo "── Stopping Keepalived on Director-1 (MASTER) ──"
    docker stop lvs-director-1
    echo "  Waiting 5s for failover..."
    sleep 5

    echo ""
    echo "── After failover ──"
    for dir in lvs-director-2; do
        HAS_VIP=$(docker exec ${dir} ip addr show 2>/dev/null | grep -c '192.168.100.100' || echo "0")
        if [ "$HAS_VIP" -gt 0 ] 2>/dev/null; then
            echo "  ✅ VIP moved to: ${dir}"
        fi
    done

    echo ""
    echo "── Testing VIP from client ──"
    docker exec lvs-client curl -s http://192.168.100.100/api/info.json 2>/dev/null | jq . || echo "  (VIP not yet responding)"
    echo ""
    echo "✅ Failover test complete. Run './manage.sh recover' to restore."
}

cmd_recover() {
    echo "🔧 Recovering Director-1..."
    docker start lvs-director-1
    echo "  Waiting 5s for preemption..."
    sleep 5

    echo ""
    echo "── After recovery ──"
    for dir in lvs-director-1 lvs-director-2; do
        HAS_VIP=$(docker exec ${dir} ip addr show 2>/dev/null | grep -c '192.168.100.100' || echo "0")
        if [ "$HAS_VIP" -gt 0 ] 2>/dev/null; then
            echo "  ✅ VIP is on: ${dir}"
        fi
    done
    echo ""
    echo "✅ Recovery complete."
}

cmd_ipvs() {
    echo "── IPVS Table (Active Director) ──"
    docker exec lvs-director-1 ipvsadm -Ln --stats 2>/dev/null || \
    docker exec lvs-director-2 ipvsadm -Ln --stats 2>/dev/null || \
    echo "No active director found"
}

cmd_logs() {
    echo "── Keepalived Logs ──"
    for dir in lvs-director-1 lvs-director-2; do
        echo ""
        echo "  ${dir}:"
        docker logs --tail 20 ${dir} 2>&1 || echo "  (unreachable)"
    done
}

# ──────────────────────────────────────────────
# Main dispatch
# ──────────────────────────────────────────────
case "${1:-help}" in
    up)        cmd_up ;;
    down)      cmd_down ;;
    destroy)   cmd_destroy ;;
    status)    cmd_status ;;
    test)      cmd_test ;;
    exec)      cmd_exec "${2:-}" ;;
    failover)  cmd_failover ;;
    recover)   cmd_recover ;;
    ipvs)      cmd_ipvs ;;
    logs)      cmd_logs ;;
    *)         usage ;;
esac
