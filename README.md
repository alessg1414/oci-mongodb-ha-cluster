# Enterprise High Availability (HA) & Disaster Recovery (DR) Infrastructure
> **Production-Grade Multi-Site Network Design & OCI MongoDB Replica Set Architecture**

> [!NOTE]  
> **Academic Project Status**: This repository is an ongoing university project. High Availability (HA) clustering via **Corosync** and **Pacemaker** for virtual machine orchestration is currently pending implementation in an upcoming milestone.

---

## Executive Summary

This repository presents the architecture, implementation, and failover validation for a resilient **High Availability (HA) and Disaster Recovery (DR)** infrastructure designed for high-concurrency database workloads. Taking the production environment of **TicoHost Colocation S.A.** as an enterprise baseline, this project demonstrates zero-data-loss database replication, dynamic leader election, and multi-site network redundancy.

The active deployment leverages **Oracle Cloud Infrastructure (OCI)** to host a multi-node **MongoDB Replica Set (`rsJobBridge`)** hosting production data for the **JobBridge** platform. The architecture ensures zero Recovery Point Objective (RPO) and rapid sub-minute failover without manual intervention during hardware or instance-level disruptions.

---

## Completed Architecture & Scope

This repository documents **strictly completed and verified technical milestones**. Pending software-layer configurations (such as application-level virtual IPs or application server process managers) are excluded from this operational baseline.

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
                                                             | MongoDB 7.0 (Arbiter)   |
                                                             |      Port: 27018        |
                                                             +-------------------------+

### 1. Database Availability Layer (OCI Active Deployment)
* **Replica Set Cluster (`rsJobBridge`)**: Deployed on Ubuntu Server 22.04.5 LTS compute nodes across distinct OCI Fault Domains.
* **Primary Node (`node1-active` / `10.0.1.10`)**: Handles all active write operations and coordinates synchronous WAL/oplog replication.
* **Secondary Node (`node2-passive` / `10.0.1.11`)**: Maintains a real-time, byte-for-byte replica of the primary dataset and stands ready for automatic election promotion.
* **Quorum Arbiter (`node2-passive` / `Port 27018`)**: Provides the critical tie-breaking vote during election cycles without storing duplicate data payload.
* **Data Integrity Verification**: Successfully backed up and restored the complete 5-collection production dataset (`users`, `services`, `contracts`, `messages`, `ratings`) via `mongodump` and `mongorestore`.

### 2. Multi-Site Enterprise Network Topography (Cisco Packet Tracer)
* **Tier III Physical Infrastructure Baseline**: Designed a dual-data-center physical architecture (Cartago Primary & Heredia DR) utilizing redundant Caterpillar diesel generators, APC Symmetra A/B power distribution units, and Vertiv CRAC cooling systems.
* **Carrier-Grade Routing & Switching**: Implemented a full-mesh WAN topology across four edge routers running **BGP Multihoming** and **OSPF dynamic routing**.
* **Switching Redundancy**: Applied **Rapid Spanning Tree Protocol (RSTP)** and **LACP EtherChannel** across Catalyst Core and Distribution switches to eliminate Layer 2 single points of failure.

---

## Architectural Constraint: Free-Tier Quorum Design

> ⚠️ **Design Note & Enterprise Deployment Comparison**

To adhere strictly to the resource bounds of the **OCI Always Free Tier**, the voting quorum for the MongoDB Replica Set was implemented using a **2-node Virtual Machine model**:

1. **Academic/Cost-Optimized Implementation**: `VM1` hosts the Primary database instance (`:27017`). `VM2` hosts both the Secondary database instance (`:27017`) and a lightweight, isolated Arbiter process (`:27018`). This guarantees the odd-numbered vote threshold (3 total votes) required for automated consensus under Raft-like leader election.
2. **Enterprise Production Standard**: In corporate enterprise deployments, running an Arbiter on the same underlying host as a Secondary data node creates a shared failure domain. Standard enterprise architectures mandate a **minimum 3 independent physical/virtual host topology** (or 2 data nodes + 1 isolated third-party Arbiter host) to eliminate split-brain risks and preserve quorum should any single host fail completely.

---

## Verified Failover Test Results

The architecture underwent empirical disruption testing to validate failover capabilities:

| Test Scenario | Action Executed | Observed Result | RTO / Recovery Status |
| :--- | :--- | :--- | :--- |
| **Primary Node Termination** | Forced shutdown of `mongod` service on `node1-active`. | `rsJobBridge` quorum loss detected by `node2` and Arbiter. `node2-passive` promoted to **Primary**. | **< 30 Seconds** (Zero Data Loss) |
| **Post-Failover Write** | Executed document insertion against the newly promoted Primary (`node2`). | Transaction accepted and committed to oplog. | **Instantaneous** |
| **Node Reintegration** | Restarted `mongod` service on `node1-active`. | Node re-joined cluster automatically, transitioned to **Secondary**, and synced missing oplog entries. | **Automated Background Sync** |

---

## Contributor Credits

This project was engineered and documented by the following infrastructure engineering team:

* **Alessandro Garita Guevara**: OCI Core Infrastructure, VCN & Security Architecture, System Design.
* **Javier Núñez Sánchez**: Enterprise Packet Tracer Network Topology, BGP/OSPF Full-Mesh Routing.
* **Marco Ramírez Acuña**: MongoDB Replica Set Clustering, Quorum Configuration & Failover Runbook Execution.

---
*For detailed setup instructions, network configuration parameters, and runbooks, refer to the [`docs/`](./docs) directory.*