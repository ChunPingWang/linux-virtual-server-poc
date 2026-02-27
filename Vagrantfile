# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# ============================================================================
# LVS (Linux Virtual Server) PoC - DSR (Direct Server Return) Mode
# ============================================================================

VAGRANT_BOX = "bento/ubuntu-22.04"

# Node definitions
DIRECTORS = [
  { name: "lvs-director-1", ip: "192.168.100.10", role: "MASTER", priority: 100 },
  { name: "lvs-director-2", ip: "192.168.100.11", role: "BACKUP", priority: 90  },
]

REAL_SERVERS = [
  { name: "real-server-1", ip: "192.168.100.21", weight: 3 },
  { name: "real-server-2", ip: "192.168.100.22", weight: 2 },
]

VIP = "192.168.100.100"

Vagrant.configure("2") do |config|

  config.vm.boot_timeout = 600

  # ──────────────────────────────────────────────
  # Global VirtualBox provider settings
  # ──────────────────────────────────────────────
  config.vm.provider "virtualbox" do |vb|
    vb.gui = false
    vb.linked_clone = true
  end

  # ──────────────────────────────────────────────
  # LVS Directors (Active / Standby)
  # ──────────────────────────────────────────────
  DIRECTORS.each do |director|
    config.vm.define director[:name] do |node|
      node.vm.box = VAGRANT_BOX
      node.vm.hostname = director[:name]

      # Service network (LVS traffic)
      node.vm.network "private_network", ip: director[:ip]

      node.vm.provider "virtualbox" do |v|
        v.memory = 512
        v.cpus = 1
        v.name = director[:name]
      end

      # Provision: install IPVS + Keepalived
      node.vm.provision "shell", path: "scripts/provision-director.sh",
        args: [
          director[:ip],
          director[:role],
          director[:priority].to_s,
          VIP,
          REAL_SERVERS.map { |rs| "#{rs[:ip]}:#{rs[:weight]}" }.join(",")
        ]
    end
  end

  # ──────────────────────────────────────────────
  # Real Servers (Backend Nginx)
  # ──────────────────────────────────────────────
  REAL_SERVERS.each do |rs|
    config.vm.define rs[:name] do |node|
      node.vm.box = VAGRANT_BOX
      node.vm.hostname = rs[:name]

      node.vm.network "private_network", ip: rs[:ip]

      node.vm.provider "virtualbox" do |v|
        v.memory = 384
        v.cpus = 1
        v.name = rs[:name]
      end

      # Provision: install Nginx + DSR loopback config
      node.vm.provision "shell", path: "scripts/provision-realserver.sh",
        args: [rs[:ip], rs[:name], VIP]
    end
  end

  # ──────────────────────────────────────────────
  # Test Client
  # ──────────────────────────────────────────────
  config.vm.define "client" do |node|
    node.vm.box = VAGRANT_BOX
    node.vm.hostname = "client"

    node.vm.network "private_network", ip: "192.168.100.50"

    node.vm.provider "virtualbox" do |v|
      v.memory = 384
      v.cpus = 1
      v.name = "lvs-client"
    end

    node.vm.provision "shell", path: "scripts/provision-client.sh"
  end

end
