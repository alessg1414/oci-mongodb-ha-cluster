# Application-Layer Clustering: Corosync, Pacemaker & Cloud-Native VIP

---

## 1. Overview & Scope

This document details the **application-layer high availability tier**, implemented using **Corosync** and **Pacemaker** to orchestrate a floating Virtual IP (VIP) and an HTTP service across the two compute nodes described in [`01-architecture.md`](./01-architecture.md). This tier operates independently from, and in addition to, the MongoDB Replica Set consensus mechanism documented in that same file.

This tier addresses a failure domain the database layer alone cannot cover: **which node the client actually connects to**. The MongoDB Replica Set guarantees the *data* survives a node failure; this clustering layer guarantees the *access point* survives a node failure as well.

> [!NOTE]
> **Demonstration Service Scope**: The service placed under Pacemaker control for this milestone is an Apache HTTP server on `TCP 3000`, used to provide empirical proof of the failover mechanism. It is **not** a reverse proxy for the JobBridge Node.js/Express backend (documented separately on port `5000`), which was not deployed to these instances. This distinction is kept explicit throughout this document to accurately reflect implementation scope.

---

## 2. Why a Cloud-Native VIP Approach Was Required

In a traditional on-premises datacenter, a floating IP is typically implemented with `ocf:heartbeat:IPaddr2`, which manipulates the IP directly at the Linux kernel/interface level and relies on gratuitous ARP for the network fabric to learn the new location.

This mechanism is **insufficient in Oracle Cloud Infrastructure**. A private IP in OCI must also be recognized at the Virtual Cloud Network fabric level — specifically, bound to a given VNIC — independent of whatever is configured inside the guest operating system. Configuring an address purely inside Linux without also reassigning it at the VNIC level results in a VIP that is unreachable from other hosts in the subnet after a failover.

To resolve this, the VIP was implemented as an OCI **secondary private IP**, reassigned between VNICs via the OCI CLI, and coordinated by a custom Pacemaker OCF resource agent that performs both the cloud-side reassignment and the local interface configuration as a single atomic resource action.

---

## 3. Cluster Topology & Managed Resources

```
                      +---------------------------------------------------+
                      |            Oracle Cloud Infrastructure            |
                      |               VCN: 10.0.0.0/16                    |
                      |            Subnet: 10.0.1.0/24                    |
                      +-------------------------+-------------------------+
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
         +------------v------------+                         +------------v------------+
         |   vnic-node1 (10.0.1.10)|                         |  vnic-node2 (10.0.1.11) |
         |     Fault Domain 1      |                         |     Fault Domain 2      |
         +-------------------------+                         +-------------------------+
         | Corosync + Pacemaker    |<==== Cluster Heartbeat =>| Corosync + Pacemaker    |
         | web_jobbridge (Apache)  |        (UDP 5404-5406)   | web_jobbridge (standby) |
         | vip_jobbridge (VIP)     |                         | vip_jobbridge (standby) |
         +-------------------------+                         +-------------------------+
                      \                                                   /
                       \_______________ Floating VIP ____________________/
                                    10.0.1.100:3000
                          (Reassigned via OCI CLI + Instance Principal)
```

### Node Roles

| Node | Hostname | Private IP | Cluster Role |
| :--- | :--- | :--- | :--- |
| `VM1` | `vnic-node1` | `10.0.1.10` | Preferred node (`location` score `100`) |
| `VM2` | `vnic-node2` | `10.0.1.11` | Standby node |
| Floating resource | — | `10.0.1.100` | OCI Secondary Private IP, managed by Pacemaker |

### Managed Resources

| Resource | Resource Agent | Function |
| :--- | :--- | :--- |
| `ha_demo` | `ocf:pacemaker:Dummy` | Auxiliary resource used to validate baseline cluster resource migration before introducing a real service. |
| `vip_jobbridge` | `ocf:jobbridge:oci-vip` | Custom OCF agent. Reassigns `10.0.1.100` at the OCI VNIC level and configures the interface (`ens3`) on the active node. |
| `web_jobbridge` | `systemd:apache2` | Apache HTTP service, released from `systemd` autonomous control and placed under exclusive Pacemaker orchestration. |

### Constraints

* **Location**: `web_jobbridge prefers vnic-node1=100` — the cluster actively rebalances back to `vnic-node1` once it rejoins healthy.
* **Colocation**: `web_jobbridge with vip_jobbridge` at score `INFINITY` — both resources are mandatory co-located on the same node.
* **Ordering**: `start vip_jobbridge then start web_jobbridge` — the floating IP must be provisioned and reachable before the HTTP service is started.

---

## 4. Cluster Bring-Up

Executed on both nodes unless otherwise noted.

### Step 4.1: Package Installation

```bash
sudo apt update
sudo apt install -y pacemaker corosync pcs resource-agents
sudo systemctl enable --now pcsd

```

> **Note**: The default Corosync installation ships with a single-node local configuration (cluster name `debian`, `ring0_addr 127.0.0.1`). This default configuration was destroyed prior to cluster creation to prevent conflicts with `jobbridge-ha`:
>
> ```bash
> sudo pcs cluster stop
> sudo pcs cluster destroy
>
> ```

### Step 4.2: Local Firewall Adjustment

The base Ubuntu image on OCI ships with `iptables` rules terminating in a final `REJECT`, independent of `ufw` (which was inactive). This initially blocked `pcsd` and Corosync heartbeat traffic despite successful ICMP connectivity between nodes:

```bash
sudo iptables -I INPUT -s 10.0.1.0/24 -p tcp --dport 2224 -j ACCEPT
sudo iptables -I INPUT -s 10.0.1.0/24 -p udp --dport 5404:5406 -j ACCEPT
sudo iptables -I INPUT -s 10.0.1.0/24 -p tcp --dport 3000 -j ACCEPT
sudo netfilter-persistent save

```

### Step 4.3: Mutual Node Authentication

```bash
# On both nodes
sudo passwd hacluster

# From one node only
sudo pcs host auth vnic-node1 vnic-node2 -u hacluster

```

### Step 4.4: Cluster Creation

```bash
sudo pcs cluster setup jobbridge-ha \
  vnic-node1 addr=10.0.1.10 \
  vnic-node2 addr=10.0.1.11

sudo pcs cluster start --all
sudo pcs cluster enable --all
sudo pcs status

```

### Step 4.5: Fencing & Quorum Baseline

```bash
sudo pcs property set stonith-enabled=false

```

> [!NOTE]
> **Fencing scope**: STONITH was disabled to permit failover testing without a supported fencing device in this academic environment. This is an explicit lab simplification and is not presented as a production-grade configuration; a production deployment requires a functioning fencing mechanism to eliminate split-brain risk.
>
> **Quorum behavior**: `no-quorum-policy=ignore` was evaluated but **not applied** — the default two-node quorum behavior generated by Corosync (`Expected votes: 2`, `Quorum: 1`, flag `2Node`) proved sufficient for the failover scenarios validated in this milestone. This should not be read as equivalent to a production-hardened quorum policy; it reflects the specific behavior observed under the tests documented in Section 6.

---

## 5. Cloud-Native VIP Integration

### Step 5.1: Manual Pre-Validation

Before automating the mechanism, the reassignment path was validated by hand to confirm feasibility:

```bash
# Assign the VIP to vnic-node1's VNIC via OCI CLI, then configure it locally
sudo ip addr add 10.0.1.100/24 dev ens3 label ens3:1

# From vnic-node2, confirm the service is reachable through the VIP
curl http://10.0.1.100:3000

# Reassign the secondary private IP to vnic-node2's VNIC
oci network vnic assign-private-ip \
  --vnic-id <VNIC_OCID_NODE2> \
  --ip-address 10.0.1.100 \
  --unassign-if-already-assigned

```

This confirmed the same endpoint (`10.0.1.100:3000`) remained reachable end-to-end after a manual reassignment, before any automation was introduced.

### Step 5.2: OCI CLI & Instance Principal Authentication

The OCI CLI was installed on both nodes:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
source ~/.bashrc
oci --version

```

Rather than distributing personal API key pairs to each instance, authentication was implemented via **OCI Instance Principal**, scoped to a Dynamic Group matching only the two cluster instances by OCID:

```
Any {
  instance.id = '<INSTANCE_OCID_NODE1>',
  instance.id = '<INSTANCE_OCID_NODE2>'
}

```

The associated IAM policy grants the minimum permissions required for VIP reassignment, and nothing broader:

```
Allow dynamic-group jobbridge-ha-dg to use private-ips in tenancy
Allow dynamic-group jobbridge-ha-dg to use vnics in tenancy
Allow dynamic-group jobbridge-ha-dg to use subnets in tenancy

```

Verification:

```bash
oci network private-ip list \
  --vnic-id <VNIC_OCID> \
  --auth instance_principal \
  --output table

```

### Step 5.3: Custom OCF Resource Agent

A custom OCF-compliant resource agent, `ocf:jobbridge:oci-vip`, was developed and installed at `/usr/lib/ocf/resource.d/jobbridge/oci-vip` on both nodes. It implements the standard OCF action set:

* **`start`**: Resolves the local node's VNIC OCID, reassigns `10.0.1.100` via `oci network vnic assign-private-ip --unassign-if-already-assigned`, then adds the address to `ens3`.
* **`stop`**: Removes the address from `ens3` and unassigns it at the OCI level.
* **`monitor`**: Returns success (`0`) only when the VIP is confirmed present **both** in OCI and on the local interface; returns `OCF_NOT_RUNNING` when absent from both, and a generic error when the two states disagree.
* **`validate-all`**: Confirms the OCI CLI binary is executable, the target interface exists, and both VNIC OCID parameters are supplied.

The full script is available at [`scripts/oci-vip-resource-agent.sh`](../scripts/oci-vip-resource-agent.sh).

### Step 5.4: Resource Registration

```bash
sudo pcs resource create vip_jobbridge ocf:jobbridge:oci-vip \
  vip=10.0.1.100 \
  prefix=24 \
  interface=ens3 \
  oci_path=/home/ubuntu/bin/oci \
  node1_name=vnic-node1 \
  node2_name=vnic-node2 \
  vnic_node1=<VNIC_OCID_NODE1> \
  vnic_node2=<VNIC_OCID_NODE2> \
  op monitor interval=10s timeout=30s \
  op start timeout=90s \
  op stop timeout=90s

sudo pcs resource create web_jobbridge systemd:apache2 \
  op monitor interval=10s

sudo pcs resource meta web_jobbridge migration-threshold=1 failure-timeout=60s
sudo pcs constraint location web_jobbridge prefers vnic-node1=100

sudo pcs constraint colocation add web_jobbridge with vip_jobbridge INFINITY
sudo pcs constraint order start vip_jobbridge then start web_jobbridge

```

> **Note**: The `start`/`stop` operation timeouts were tuned to `90s` after empirical testing showed a full VIP reassignment cycle — spanning the OCI API round-trip, local interface reconfiguration, and confirmation polling — took approximately **40–45 seconds** end to end. An earlier `60s` timeout was found to be insufficient under a slower API response, which caused the resource to enter a `blocked` state requiring manual `pcs resource cleanup`.

---

## 6. Verified Failover & Failback Test Results

Testing was conducted with continuous synthetic polling against the VIP from `vnic-node2`, sampling the active node identity every 2 seconds throughout each disruption.

| Test ID | Test Scenario | Action Executed | Observed Result | Recovery Status | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **PCM-01** | **Service-Level Failure** | Stopped the `apache2` process directly (`systemctl stop apache2`) while both nodes remained online. | Pacemaker detected the monitor failure and relocated `web_jobbridge` + `vip_jobbridge` to `vnic-node2`. Once `vnic-node1` was confirmed healthy again, the location preference automatically rebalanced both resources back. | **Fully automated relocation and rebalance; no manual intervention required.** | **PASSED** |
| **PCM-02** | **Full Node Failure** | Removed `vnic-node1` from cluster membership (`pcs cluster stop`) while the instance remained powered on. | Corosync marked `vnic-node1` `OFFLINE`. Pacemaker relocated all resources to `vnic-node2`; the OCF agent reassigned the secondary private IP at the OCI VNIC level and reconfigured `ens3` on the new active node. | **~40–45 seconds** (VIP endpoint unreachable during transition, then fully restored on `vnic-node2`) | **PASSED** |
| **PCM-03** | **Node Reintegration / Failback** | Restored `vnic-node1` to cluster membership (`pcs cluster start`). | Due to the configured location preference, Pacemaker automatically migrated both resources back to `vnic-node1`, including a second live VIP reassignment. | **~40–45 seconds**, fully automated | **PASSED** |
| **PCM-04** | **Endpoint Continuity** | Queried `http://10.0.1.100:3000` continuously throughout PCM-02 and PCM-03. | The client-facing endpoint address never changed; only the responding node identity (embedded in the served page) changed across transitions. | **Single stable access point maintained throughout** | **PASSED** |

---

## 7. Relationship to the MongoDB Replica Set Layer

Pacemaker **does not** manage `mongod` on either node. This is an intentional architectural decision, not an oversight: MongoDB already implements its own leader election, replication, and automated recovery via the Raft-like consensus protocol described in [`01-architecture.md`](./01-architecture.md). Placing `mongod` under a second, independent orchestration layer would duplicate — and potentially conflict with — that native mechanism.

This produces two **independent quorum models** operating side by side on the same two hosts:

| Layer | Quorum Mechanism | Scope |
| :--- | :--- | :--- |
| MongoDB Replica Set | 3 votes (`node1-active:27017`, `node2-passive:27017`, `node2-passive:27018` Arbiter) | Database write availability and Primary election. |
| Corosync / Pacemaker | 2-node cluster membership (`Expected votes: 2`) | Application service placement and VIP ownership. |

The MongoDB Arbiter process is not registered with, nor visible to, Corosync — the two quorum mechanisms are fully independent and must be evaluated separately when assessing overall system resilience.

---

## 8. Known Limitations & Deferred Scope

| Component | Final Status | Rationale |
| :--- | :--- | :--- |
| NFS shared storage (`/uploads`) | Not implemented | OCI File Storage Mount Targets carry a billable cost outside the Always Free Tier. Additionally, using `vnic-node1` as a self-hosted NFS server would have introduced a new single point of failure directly contradicting the project's HA objective. |
| JobBridge Node.js/Express backend (`:5000`) | Not deployed | Project scope for this milestone concentrated on proving the orchestration mechanism (Pacemaker + cloud-native VIP) against a real, independently verifiable HTTP service. Apache on `:3000` fulfills that role without acting as a reverse proxy for the original backend. |
| STONITH / production fencing | Not implemented | Disabled for lab operation per Section 4.5. A production deployment requires a supported fencing device to eliminate split-brain risk. |
| Independent third Arbiter host | Not implemented | The MongoDB Arbiter runs as a co-located process on `vnic-node2` to remain within Always Free Tier constraints; see the Free-Tier Quorum Design comparison in [`01-architecture.md`](./01-architecture.md). |
