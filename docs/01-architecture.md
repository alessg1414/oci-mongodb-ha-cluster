# Architectural Overview & Topology Design

---

## 1. Executive Summary

This document details the architectural layout, high-availability topology, and voting mechanics of the **JobBridge** enterprise infrastructure. The system is architected across two distinct, complementary tiers:

1. **Active Database Availability Layer (Oracle Cloud Infrastructure)**: A multi-node MongoDB Replica Set (`rsJobBridge`) providing real-time data replication, sub-minute failover, and zero Recovery Point Objective (RPO) for application data.
2. **Physical Enterprise Network Topology (Cisco Packet Tracer Baseline)**: A Tier III multi-site network architecture modeling the enterprise data centers of **TicoHost Colocation S.A.**, featuring full-mesh edge routing, dynamic WAN protocols, and Layer 2 redundancy.

---

## 2. Multi-Site Physical Network Topology (Packet Tracer Baseline)

The enterprise network model establishes a resilient baseline connecting two physical data centers across distinct geographical locations in Costa Rica:

* **Primary Data Center**: Cartago Location
* **Disaster Recovery (DR) Data Center**: Heredia Location

+-----------------------------------------------------------------------------------+
|                            TicoHost Core WAN Backbone                             |
|                                                                                   |
|    +-----------------------+                             +-----------------------+ |
|    | Cartago Primary DC    |==== BGP Multihoming =| Heredia DR DC         | |
|    | - Edge Router CR-01   |<--- Full-Mesh OSPF ------->| - Edge Router HR-01   | |
|    | - Core Switch CS-01   |                            | - Core Switch CS-02   | |
|    | - Distribution Stack  |                            | - Distribution Stack  | |
|    +-----------+-----------+                            +-----------+-----------+ |
+----------------|----------------------------------------------------|-------------+
                 |                                                    |
                    +============ LACP / EtherChannel =============+

### Infrastructure & Physical Specifications
* **Facility Redundancy**: Both sites model Tier III standards, including Caterpillar diesel generators for power backup, dual APC Symmetra A/B UPS trains, and Vertiv CRAC HVAC systems.
* **Layer 3 Routing Architecture**:
  * **Edge Protocol**: BGP Multihoming across dual Internet Service Provider (ISP) connections for autonomous system transit redundancy.
  * **Internal Routing**: OSPF (Open Shortest Path First) configured across a full-mesh backbone between internal core and distribution routers.
* **Layer 2 Switching Redundancy**:
  * **Link Aggregation**: LACP EtherChannel links connecting Core switches to Distribution layer stacks to maximize bandwidth and survive single-link failure.
  * **Loop Prevention**: Rapid Spanning Tree Protocol (RSTP / 802.1w) enabled across all VLANs to provide sub-second loop protection and convergence during trunk line degradation.

---

## 3. Database Availability Layer (OCI Active Deployment)

The active production database for **JobBridge** is hosted on **Oracle Cloud Infrastructure (OCI)** inside a dedicated Virtual Cloud Network (VCN).

                      +---------------------------------------------------+
                      |            Oracle Cloud Infrastructure            |
                      |            VCN: 10.0.0.0/16 (us-ashburn-1)        |
                      |         Subnet: 10.0.1.0/24 (Regional)           |
                      +-------------------------+-------------------------+
                                                |
                      +-------------------------+-------------------------+
                      |                                                   |
         +------------v------------+                         +------------v------------+
         | VM1 (node1-active)      |                         | VM2 (node2-passive)     |
         | IP: 10.0.1.10           |                         | IP: 10.0.1.11           |
         | OCI Fault Domain: FD-1  |                         | OCI Fault Domain: FD-2  |
         +-------------------------+                         +-------------------------+
         |  MongoDB 7.0 (Primary)  |<== Replication Stream =>| MongoDB 7.0 (Secondary) |
         |      Port: 27017        |       (Async/Oplog)     |      Port: 27017        |
         |     [Priority: 2]       |                         |     [Priority: 1]       |
         +-------------------------+                         +-------------------------+
                                                             | MongoDB 7.0 (Arbiter)   |
                                                             |      Port: 27018        |
                                                             |  [arbiterOnly: true]    |
                                                             +-------------------------+

### Network & Instance Specification
* **Cloud Provider**: Oracle Cloud Infrastructure (OCI)
* **VCN CIDR**: `10.0.0.0/16`
* **Regional Subnet**: `10.0.1.0/24` (Private subnet with NAT gateway egress)
* **Operating System**: Ubuntu Server 22.04.5 LTS
* **Database Engine**: MongoDB Community Edition 7.0

---

## 4. Replica Set Quorum & Election Mechanics

MongoDB utilizes a Consensus Protocol based on Raft for primary election and write quorum validation. A strict majority of voting members is required to elect or maintain a Primary.

### Member Breakdown & Quorum Allocation

| Node Name | IP Address | Service Port | Role / Member Type | Votes | Priority | OCI Fault Domain |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `node1-active` | `10.0.1.10` | `27017` | **Primary** (Data Node) | 1 | 2 | Fault Domain 1 |
| `node2-passive` | `10.0.1.11` | `27017` | **Secondary** (Data Node) | 1 | 1 | Fault Domain 2 |
| `node2-arbiter` | `10.0.1.11` | `27018` | **Arbiter** (Quorum Vote Only) | 1 | 0 | Fault Domain 2 |

* **Total Voting Members**: 3 (`10.0.1.10:27017`, `10.0.1.11:27017`, `10.0.1.11:27018`)
* **Quorum Threshold**: $\lceil 3 / 2 \rceil = 2$ votes required for primary promotion or write acceptance under `majority` concern.

### Replication Logic & Oplog Handling
1. **Write Lifecycle**: Writes are accepted exclusively by the Primary (`node1-active`). Every operation is logged to the operational log (`local.oplog.rs`).
2. **Replication Stream**: The Secondary node (`node2-passive`) asynchronously polls the Primary's oplog and applies transactions to maintain byte-for-byte dataset parity.
3. **Heartbeats**: All nodes exchange heartbeats every 2 seconds. If the Primary fails to respond within 10 seconds (heartbeat timeout), an election is triggered.

---

## 5. Free-Tier Quorum Design vs. Enterprise Production Standard

### Free-Tier Implementation
To operate within the resource constraints of the OCI Always Free Tier while adhering to MongoDB's odd-number voting requirement:
* The Secondary database daemon (`mongod`) and the Arbiter daemon (`mongod-arbiter`) co-exist on `VM2` (`10.0.1.11`) on different ports (`27017` vs. `27018`).
* The Arbiter stores no collection data, keeping disk footprint negligible while providing the necessary 3rd vote.

### Enterprise Production Standard
In enterprise deployments, hosting an Arbiter on the same virtual instance as a Secondary data node creates a single point of failure (SPOF) at the host layer:
* If `VM2` crashes entirely due to hypervisor failure, 2 out of 3 votes are lost, preventing `VM1` from maintaining a quorum.
* **Production Recommendation**: Deploy a 3-host topology where data nodes reside on separate physical hypervisors/instances and the Arbiter (or 3rd data replica) is provisioned on a distinct, isolated compute instance.