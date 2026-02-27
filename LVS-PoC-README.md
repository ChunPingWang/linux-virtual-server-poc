# LVS (Linux Virtual Server) PoC - DSR Mode

## Architecture

```
                            ┌─────────────────────┐
                            │      Client VM       │
                            │   192.168.100.50     │
                            └──────────┬──────────┘
                                       │
                                  Request to VIP
                                 192.168.100.100
                                       │
                    ┌──────────────────┴──────────────────┐
                    │          VRRP (Keepalived)           │
                    │                                      │
              ┌─────┴─────┐                         ┌─────┴─────┐
              │ Director-1 │    VIP Failover (HA)   │ Director-2 │
              │  MASTER    │◄──────────────────────►│  BACKUP    │
              │ .100.10    │                         │ .100.11    │
              └─────┬─────┘                         └───────────┘
                    │
              IPVS DR (DSR)
           ┌────────┼────────┐
           │        │        │
     ┌─────┴──┐ ┌──┴─────┐ ┌┴───────┐
     │  RS-1  │ │  RS-2  │ │  RS-3  │
     │  w=3   │ │  w=2   │ │  w=1   │
     │ .100.21│ │ .100.22│ │ .100.23│
     └───┬────┘ └───┬────┘ └───┬────┘
         │          │          │
         └──────────┴──────────┘
                    │
          Response DIRECTLY to Client
            (bypasses Director)
              = DSR / DR Mode
```

## Key Design Decisions

| Aspect | Choice | Rationale |
|--------|--------|-----------|
| **LB Mode** | DR (Direct Server Return) | Response bypasses Director → higher throughput |
| **Scheduling** | WRR (Weighted Round Robin) | Allows heterogeneous backend capacity |
| **HA** | Keepalived + VRRP | Industry standard, sub-second failover |
| **Health Check** | HTTP GET /health | Application-level, not just TCP |
| **Persistence** | 60s source-hash | Session affinity for stateful apps |
| **ARP Handling** | arp_ignore=1, arp_announce=2 | Prevents ARP conflicts with VIP on lo |

## Prerequisites

- VMware Workstation Pro 16+ (or VMware Fusion on macOS)
- Vagrant 2.3+
- Vagrant VMware Utility
- Vagrant VMware Desktop Plugin:
  ```bash
  vagrant plugin install vagrant-vmware-desktop
  ```

> **Alternative: VirtualBox**
> If using VirtualBox instead, change `VAGRANT_PROVIDER` in the Vagrantfile
> from `"vmware_desktop"` to `"virtualbox"` and update provider blocks accordingly.

## Quick Start

```bash
# 1. Clone / copy this project
cd lvs-poc

# 2. Make scripts executable
chmod +x manage.sh scripts/*.sh

# 3. Start the cluster
./manage.sh up

# 4. Run tests
./manage.sh test

# 5. Test failover
./manage.sh failover
./manage.sh recover
```

## Cluster Management

```bash
./manage.sh up          # Start all VMs
./manage.sh down        # Graceful shutdown
./manage.sh destroy     # Destroy all VMs
./manage.sh status      # Show cluster status
./manage.sh test        # Run full test suite
./manage.sh ssh <node>  # SSH into a node
./manage.sh failover    # Simulate director failure
./manage.sh recover     # Restore director
./manage.sh ipvs        # Show IPVS routing table
./manage.sh logs        # Show keepalived logs
```

## Test Scripts (from Client VM)

```bash
vagrant ssh client

# Full test suite
test-all.sh

# Individual tests
test-basic.sh              # Connectivity
test-distribution.sh 100   # Load distribution (100 requests)
test-performance.sh 10 500 # 500 requests, 10 concurrent
test-failover.sh 60        # Monitor failover for 60 seconds
test-dsr-verify.sh         # Packet capture to verify DSR
```

## Monitoring (from Director VMs)

```bash
vagrant ssh lvs-director-1

# Full status
lvs-status.sh

# IPVS real-time stats
sudo watch -n 1 'ipvsadm -Ln --stats'

# Keepalived state
sudo journalctl -u keepalived -f
```

## DSR Verification

To confirm DSR is working, run packet capture from the Client:

```bash
vagrant ssh client
sudo test-dsr-verify.sh
```

In another terminal, generate traffic:
```bash
vagrant ssh client
test-basic.sh
```

Expected DSR behavior:
- **Request path**: Client (`.50`) → VIP (`.100`) on Director
- **Response path**: Real Server (`.21/.22/.23`) → Client (`.50`) **directly**
- The Director only sees inbound traffic, NOT responses

## Network Diagram

```
Network: 192.168.100.0/24

 .10  ──── lvs-director-1 (MASTER, VIP .100)
 .11  ──── lvs-director-2 (BACKUP)
 .21  ──── real-server-1   (Nginx, weight=3)
 .22  ──── real-server-2   (Nginx, weight=2)
 .23  ──── real-server-3   (Nginx, weight=1)
 .50  ──── client           (Test tools)
 .100 ──── VIP (floating, managed by Keepalived)
```

## Resource Requirements

| VM | CPU | RAM | Disk |
|----|-----|-----|------|
| Director x2 | 1 core | 1 GB | 10 GB |
| Real Server x3 | 1 core | 512 MB | 10 GB |
| Client x1 | 1 core | 512 MB | 10 GB |
| **Total** | **6 cores** | **4.5 GB** | **60 GB** |

## Troubleshooting

### VIP not assigned
```bash
vagrant ssh lvs-director-1
sudo systemctl status keepalived
sudo journalctl -u keepalived -n 50
ip addr show  # Check if VIP appears
```

### Real Server not receiving traffic
```bash
vagrant ssh real-server-1
rs-status.sh                                    # Check VIP on lo, ARP settings
curl http://localhost/health                     # Verify Nginx
cat /proc/sys/net/ipv4/conf/all/arp_ignore      # Must be 1
cat /proc/sys/net/ipv4/conf/all/arp_announce     # Must be 2
```

### IPVS showing 0 connections
```bash
vagrant ssh lvs-director-1
sudo ipvsadm -Ln           # Check real servers listed
sudo ipvsadm -Ln --stats   # Check packet counters
```

## Extending This PoC

### Add HTTPS (TLS Termination at Real Servers)
```bash
# On each real server, configure Nginx with SSL
# Update keepalived: virtual_server VIP 443 + lb_kind DR
```

### Switch to IPVS Tunnel Mode (for cross-subnet DSR)
```
# In keepalived.conf, change:
lb_kind DR  →  lb_kind TUN
# Real servers need ipip tunnel instead of lo VIP
```

### Add Prometheus Monitoring
```bash
# Install ipvs_exporter on directors
# Install node_exporter on all nodes
# Deploy Prometheus + Grafana on a separate VM
```
