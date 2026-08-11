# Enterprise High Availability (HA) & Disaster Recovery (DR) Infrastructure
> **Production-Grade Multi-Site Network Design, OCI MongoDB Replica Set & Corosync/Pacemaker Application Clustering**

> [!NOTE]  
> **Academic Project Status**: This repository is a finished university project. Please note that **TicoHost Colocation S.A.** and **JobBridge** are fictional entities created solely for academic and demonstration purposes. Application-layer High Availability clustering via **Corosync** and **Pacemaker**, including cloud-native VIP failover, has been implemented and empirically validated. See [Section: Verified Failover Test Results](#verified-failover-test-results) and [`docs/05-pacemaker-corosync-vip.md`](./docs/05-pacemaker-corosync-vip.md) for full detail.

---

## Executive Summary

This repository presents the architecture, implementation, and failover validation for a resilient **High Availability (HA) and Disaster Recovery (DR)** infrastructure designed for high-concurrency database workloads. Taking the production environment of **TicoHost Colocation S.A.** as an enterprise baseline, this project demonstrates zero-data-loss database replication, dynamic leader election, cloud-native VIP orchestration, and multi-site network redundancy.

The active deployment leverages **Oracle Cloud Infrastructure (OCI)** to host a multi-node **MongoDB Replica Set (`rsJobBridge`)** hosting production data for the **JobBridge** platform, alongside an independent **Corosync/Pacemaker cluster** that provides automated failover of a floating Virtual IP and an HTTP service between the same two compute nodes. The architecture ensures zero Recovery Point Objective (RPO) at the database layer and rapid, fully automated failover — without manual intervention — during hardware, instance, or service-level disruptions at either layer.

---

## Completed Architecture & Scope

This repository documents **strictly completed and verified technical milestones**. Components not carried into the final implementation (such as NFS shared storage or the full JobBridge application backend) are explicitly identified as out of scope in [`docs/05-pacemaker-corosync-vip.md`](./docs/05-pacemaker-corosync-vip.md#8-known-limitations--deferred-scope) rather than presented as completed.

                      +---------------------------------------------------+
                      |            Oracle Cloud Infrastructure            |
                      |               VCN: 10.0.0.0/16                    |
                      |            Subnet: 10.0.1.0/24                    |
                      +-------------------------+-------------------------+
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
         +------------v------------+                         +------------v------------+
         |   VM1 (node1-active)    |                         |   VM2 (node2-passive)   |
         |       10.0.1.10         |                         |       10.0.1.11         |
         +-------------------------+                         +-------------------------+
         |  MongoDB 7.0 (Primary)  |<== Replication Stream =>| MongoDB 7.0 (Secondary) |
         |      Port: 27017        |                         |      Port: 27017        |
         +-------------------------+                         +-------------------------+
         | Corosync + Pacemaker    |<==== Cluster Heartbeat =>| Corosync + Pacemaker    |
         | web_jobbridge (Apache)  |                         | MongoDB 7.0 (Arbiter)   |
         | vip_jobbridge (VIP)     |                         |      Port: 27018        |
         +-------------------------+                         +-------------------------+
                      \_______________ Floating VIP: 10.0.1.100:3000 _____________/

### 1. Database Availability Layer (OCI Active Deployment)
* **Replica Set Cluster (`rsJobBridge`)**: Deployed on Ubuntu Server 22.04.5 LTS compute nodes across distinct OCI Fault Domains.
* **Primary Node (`node1-active` / `10.0.1.10`)**: Handles all active write operations and coordinates synchronous WAL/oplog replication.
* **Secondary Node (`node2-passive` / `10.0.1.11`)**: Maintains a real-time, byte-for-byte replica of the primary dataset and stands ready for automatic election promotion.
* **Quorum Arbiter (`node2-passive` / `Port 27018`)**: Provides the critical tie-breaking vote during election cycles without storing duplicate data payload.
* **Data Integrity Verification**: Successfully backed up and restored the complete 5-collection production dataset (`users`, `services`, `contracts`, `messages`, `ratings`) via `mongodump` and `mongorestore`.

### 2. Application Availability Layer (Corosync & Pacemaker)
* **Cluster (`jobbridge-ha`)**: Corosync-backed Pacemaker cluster spanning the same two OCI compute nodes, orchestrating service placement independently of the MongoDB Replica Set.
* **Cloud-Native Floating VIP (`10.0.1.100`)**: Implemented as an OCI secondary private IP reassigned between VNICs via a custom OCF resource agent (`ocf:jobbridge:oci-vip`), authenticated through OCI Instance Principal — not `ocf:heartbeat:IPaddr2`, which cannot reassign IPs at the cloud fabric level.
* **Managed HTTP Service (`web_jobbridge`)**: Apache HTTP server on `TCP 3000`, released from autonomous `systemd` control and placed under exclusive Pacemaker orchestration with mandatory colocation and ordering against the VIP resource.
* **Empirically Validated Failover**: Both service-level failures (direct process termination) and full node failures (`pcs cluster stop`) trigger fully automated relocation and VIP reassignment, with automatic failback once the preferred node rejoins.

### 3. Multi-Site Enterprise Network Topography (Cisco Packet Tracer)
* **Tier III Physical Infrastructure Baseline**: Designed a dual-data-center physical architecture (Cartago Primary & Heredia DR) utilizing redundant Caterpillar diesel generators, APC Symmetra A/B power distribution units, and Vertiv CRAC cooling systems.
* **Carrier-Grade Routing & Switching**: Implemented a full-mesh WAN topology across four edge routers running **BGP Multihoming** and **OSPF dynamic routing**.
* **Switching Redundancy**: Applied **Rapid Spanning Tree Protocol (RSTP)** and **LACP EtherChannel** across Catalyst Core and Distribution switches to eliminate Layer 2 single points of failure.
* **Gateway Redundancy**: Configured **HSRP** across both Core switches at each site, providing a virtual gateway IP with automatic active/standby failover and preempt-based failback.
* Full device-level configuration is documented in [`docs/06-network-topology-packet-tracer.md`](./docs/06-network-topology-packet-tracer.md). The original simulation file is available at [`topology/TicoHost_HATopology.pkt`](./topology/TicoHost_HATopology.pkt) (requires [Cisco Packet Tracer](https://www.netacad.com/courses/packet-tracer) to open).

---

## Architectural Constraint: Free-Tier Quorum Design

> ⚠️ **Design Note & Enterprise Deployment Comparison**

To adhere strictly to the resource bounds of the **OCI Always Free Tier**, the voting quorum for the MongoDB Replica Set was implemented using a **2-node Virtual Machine model**:

1. **Academic/Cost-Optimized Implementation**: `VM1` hosts the Primary database instance (`:27017`). `VM2` hosts both the Secondary database instance (`:27017`) and a lightweight, isolated Arbiter process (`:27018`). This guarantees the odd-numbered vote threshold (3 total votes) required for automated consensus under Raft-like leader election.
2. **Enterprise Production Standard**: In corporate enterprise deployments, running an Arbiter on the same underlying host as a Secondary data node creates a shared failure domain. Standard enterprise architectures mandate a **minimum 3 independent physical/virtual host topology** (or 2 data nodes + 1 isolated third-party Arbiter host) to eliminate split-brain risks and preserve quorum should any single host fail completely.

---

## Verified Failover Test Results

The architecture underwent empirical disruption testing across both the database and application clustering layers to validate failover capabilities.

### Database Layer (MongoDB Replica Set)

| Test Scenario | Action Executed | Observed Result | RTO / Recovery Status |
| :--- | :--- | :--- | :--- |
| **Primary Node Termination** | Forced shutdown of `mongod` service on `node1-active`. | `rsJobBridge` quorum loss detected by `node2` and Arbiter. `node2-passive` promoted to **Primary**. | **< 30 Seconds** (Zero Data Loss) |
| **Post-Failover Write** | Executed document insertion against the newly promoted Primary (`node2`). | Transaction accepted and committed to oplog. | **Instantaneous** |
| **Node Reintegration** | Restarted `mongod` service on `node1-active`. | Node re-joined cluster automatically, transitioned to **Secondary**, and synced missing oplog entries. | **Automated Background Sync** |

### Application Layer (Corosync & Pacemaker)

| Test Scenario | Action Executed | Observed Result | RTO / Recovery Status |
| :--- | :--- | :--- | :--- |
| **Service-Level Failure** | Stopped the `apache2` process directly while both nodes remained online. | Pacemaker relocated `web_jobbridge` and `vip_jobbridge` to `vnic-node2`, then automatically rebalanced back to `vnic-node1` once healthy. | **Fully Automated** |
| **Full Node Failure** | Removed `vnic-node1` from cluster membership (`pcs cluster stop`) while the instance stayed powered on. | Pacemaker relocated all resources to `vnic-node2`; the custom OCF agent reassigned the floating VIP at the OCI VNIC level. | **~40–45 Seconds** |
| **Node Reintegration / Failback** | Restored `vnic-node1` to cluster membership. | Both resources — including a second live VIP reassignment — automatically migrated back to the preferred node. | **~40–45 Seconds, Fully Automated** |

> Full test methodology, resource agent internals, and quorum design notes are documented in [`docs/05-pacemaker-corosync-vip.md`](./docs/05-pacemaker-corosync-vip.md).

---

## Contributor Credits

This project was engineered and documented by the following infrastructure engineering team:

* **[Alessandro Garita Guevara](https://github.com/alessg1414)**: OCI Core Infrastructure, VCN & Security Architecture, System Design, Quorum Configuration.
* **[Javier Núñez Sánchez](https://github.com/aleNu93)**: Enterprise Packet Tracer Network Topology, BGP/OSPF Full-Mesh Routing.
* **[Marco Ramírez Acuña](https://github.com/jolicoton)**: MongoDB Replica Set Clustering, Failover Runbook Execution.

---

## Documentation Index

| Document | Contents |
| :--- | :--- |
| [`01-architecture.md`](./docs/01-architecture.md) | Full system topology, network design, and MongoDB Replica Set quorum mechanics. |
| [`02-setup-guide.md`](./docs/02-setup-guide.md) | OCI provisioning and MongoDB cluster installation, step by step. |
| [`03-ha-testing-runbook.md`](./docs/03-ha-testing-runbook.md) | Formal MongoDB failover/failback test procedures and results. |
| [`04-disaster-recovery.md`](./docs/04-disaster-recovery.md) | Backup, archival, and cold-restoration runbooks. |
| [`05-pacemaker-corosync-vip.md`](./docs/05-pacemaker-corosync-vip.md) | Corosync/Pacemaker cluster bring-up, cloud-native VIP integration, and application-layer failover test results. |
| [`06-network-topology-packet-tracer.md`](./docs/06-network-topology-packet-tracer.md) | Full dual-site network build: VLANs, EtherChannel, RSTP, OSPF, HSRP, and DHCP, device by device. |
| [`topology/TicoHost_HATopology.pkt`](./topology/TicoHost_HATopology.pkt) | Cisco Packet Tracer simulation file — the live, importable topology described in document 06. |

---
*For detailed setup instructions, network configuration parameters, and runbooks, refer to the [`docs/`](./docs) directory.*