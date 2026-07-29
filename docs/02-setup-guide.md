# OCI Provisioning & MongoDB Cluster Setup Guide

---

## 1. Overview & Infrastructure Requirements

This guide details the step-by-step procedure for provisioning the Oracle Cloud Infrastructure (OCI) environment, configuring system-level dependencies, installing MongoDB 7.0 Community Edition, and initializing the `rsJobBridge` Replica Set.

### Target Environment Specifications
* **Cloud Provider**: Oracle Cloud Infrastructure (OCI)
* **Operating System**: Ubuntu Server 22.04.5 LTS
* **Instances**:
  * `VM1` (`node1-active`): `10.0.1.10`
  * `VM2` (`node2-passive`): `10.0.1.11`
* **Network VCN Subnet**: `10.0.1.0/24`

---

## 2. OCI Network & Security List Configuration

Before launching compute instances, configure the Security List attached to your regional subnet to permit inter-node communication across required ports.

### Required Ingress Rules

| Source CIDR | IP Protocol | Port Range | Description |
| :--- | :--- | :--- | :--- |
| `10.0.1.0/24` | TCP | `27017` | MongoDB Primary / Secondary Database Port |
| `10.0.1.0/24` | TCP | `27018` | MongoDB Isolated Arbiter Port |
| `0.0.0.0/0` | TCP | `22` | SSH Administration Access |

> **Note**: For production deployments, restrict SSH access (`22`) to specific trusted admin IP ranges or VPN gateways.

---

## 3. Operating System Hardening & Dependencies

Execute the following setup commands on **both compute instances** (`10.0.1.10` and `10.0.1.11`).

### Step 3.1: Hostname Resolution
Edit `/etc/hosts` on both nodes to ensure reliable hostname resolution:

```bash
sudo nano /etc/hosts

```

Append the following static mappings:

```text
10.0.1.10 node1-active
10.0.1.11 node2-passive

```

### Step 3.2: Kernel Parameters & Limits

Adjust kernel settings to prevent memory and file handle exhaustion under database load:

```bash
# Set ulimits for the current and future sessions
sudo bash -c 'cat <<EOF>> /etc/security/limits.conf
mongodb soft nofile 64000
mongodb hard nofile 64000
mongodb soft nproc 64000
mongodb hard nproc 64000
EOF'

# Disable Transparent Huge Pages (THP)
sudo systemctl disable --now snapd 2>/dev/null || true
echo "never" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo "never" | sudo tee /sys/kernel/mm/transparent_hugepage/defrag

```

---

## 4. Installing MongoDB 7.0 Community Edition

Run the following commands on **both `VM1` and `VM2**`:

```bash
# Import the official MongoDB public GPG key
gnupg
curl -fsSL [https://www.mongodb.org/static/pgp/server-7.0.asc](https://www.mongodb.org/static/pgp/server-7.0.asc) | \
  sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg

# Add the official MongoDB repository for Ubuntu 22.04
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] [https://repo.mongodb.org/apt/ubuntu](https://repo.mongodb.org/apt/ubuntu) jammy/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# Update package index and install MongoDB components
sudo apt-get update
sudo apt-get install -y mongodb-org mongosh

```

---

## 5. Service Provisioning & Configuration

### Step 5.1: Configure Node 1 (`10.0.1.10`)

Copy the provided `config/mongod-node1.conf` template to `/etc/mongod.conf`. Ensure network binding and replica set name are properly declared:

```bash
sudo cp config/mongod-node1.conf /etc/mongod.conf
sudo systemctl enable mongod
sudo systemctl restart mongod

```

### Step 5.2: Configure Node 2 (`10.0.1.11`) Data Node

Copy Part A of `config/mongod-node2.conf` to `/etc/mongod.conf`:

```bash
sudo cp config/mongod-node2.conf /etc/mongod.conf
sudo systemctl enable mongod
sudo systemctl restart mongod

```

### Step 5.3: Configure Node 2 (`10.0.1.11`) Isolated Arbiter

Provision the dedicated directory structure, systemd service, and configuration file for the Arbiter instance running on port `27018`:

```bash
# 1. Create dedicated data directory and assign ownership
sudo mkdir -p /var/lib/mongodb-arbiter
sudo chown -R mongodb:mongodb /var/lib/mongodb-arbiter

# 2. Deploy Arbiter config
sudo cp config/mongod-node2-arbiter.conf /etc/mongod-arbiter.conf

# 3. Create Systemd Service for Arbiter
sudo bash -c 'cat <<EOF> /etc/systemd/system/mongod-arbiter.service
[Unit]
Description=MongoDB Database Server (Arbiter Instance)
Documentation=[https://docs.mongodb.org/manual](https://docs.mongodb.org/manual)
After=network-online.target
Wants=network-online.target

[Service]
User=mongodb
Group=mongodb
EnvironmentFile=-/etc/default/mongod
ExecStart=/usr/bin/mongod --config /etc/mongod-arbiter.conf
PIDFile=/var/run/mongodb/mongod-arbiter.pid
LimitFSIZE=infinity
LimitCPU=infinity
LimitAS=infinity
LimitNOFILE=64000
LimitNPROC=64000
TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF'

# 4. Enable and start the Arbiter service
sudo systemctl daemon-reload
sudo systemctl enable mongod-arbiter
sudo systemctl start mongod-arbiter

```

---

## 6. Replica Set Initialization

Once all database processes are active, initiate the cluster from `VM1` (`10.0.1.10`):

1. Transfer `scripts/init-replica-set.js` to `VM1`.
2. Run the initialization script via `mongosh`:

```bash
mongosh mongodb://10.0.1.10:27017 init-replica-set.js

```

3. Verify cluster convergence and member state:

```bash
mongosh --eval "rs.status().members.map(m => ({ name: m.name, stateStr: m.stateStr }))"

```

Expected Output:

```json
[
  { "name": "10.0.1.10:27017", "stateStr": "PRIMARY" },
  { "name": "10.0.1.11:27017", "stateStr": "SECONDARY" },
  { "name": "10.0.1.11:27018", "stateStr": "ARBITER" }
]

```
