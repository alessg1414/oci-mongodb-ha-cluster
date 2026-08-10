# Multi-Site Network Topology: Cisco Packet Tracer Implementation

---

## 1. Overview & Scope

This document details the complete Layer 2/Layer 3 network configuration implemented for the **TicoHost Colocation S.A.** dual-site topology, modeled in Cisco Packet Tracer as the physical network baseline described in [`01-architecture.md`](./01-architecture.md). It documents build order, exact device-level configuration, and the technical rationale behind each design decision, so that the architecture can be reproduced end to end without prior context on the project.

This tier is independent from — and complementary to — the OCI-hosted MongoDB Replica Set and Corosync/Pacemaker application clustering documented in `01-architecture.md` and [`05-pacemaker-corosync-vip.md`](./05-pacemaker-corosync-vip.md). Where those layers provide compute and database-level resilience, this network model demonstrates redundancy at the physical infrastructure and routing/switching layer expected of a Tier III colocation facility.

---

## 2. Site Architecture

The topology implements two physically independent, mirrored data centers:

* **Primary Site**: Heredia
* **Disaster Recovery (DR) Site**: Cartago

Both sites are interconnected via four full-mesh WAN links between their edge routers. Each site is autonomous and capable of independent operation should the other become unavailable.

Each site is organized into four hierarchical layers plus the server tier:

| Layer | Devices | Function |
| :--- | :--- | :--- |
| Edge | 2x Cisco ISR 4331 routers | Dual-ISP connectivity (multihoming) and inter-site WAN links |
| Core | 2x Catalyst 3650-24PS switches | Layer 3 routing, VLAN gateway (HSRP), OSPF |
| Distribution | 2x Catalyst 2960 switches | Layer 2 aggregation between access and core |
| Access | 4x Catalyst 2960 switches | Server connectivity and VLAN assignment |
| Servers | 20 client-facing + 2 internal | Client workloads; internal DNS and monitoring |

---

## 3. IP Addressing Plan

### 3.1 VLANs & Subnets

| VLAN | Name | Heredia | Cartago |
| :--- | :--- | :--- | :--- |
| 10 | Management | `192.168.10.0/24` | `192.168.110.0/24` |
| 20 | Clients | `192.168.20.0/24` | `192.168.120.0/24` |
| 30 | Internal Servers | `192.168.30.0/24` | `192.168.130.0/24` |
| 40 | Storage | `192.168.40.0/24` | `192.168.140.0/24` |

> Per-subnet convention: Core 1 holds `.1`, Core 2 holds `.2`, and the HSRP virtual IP (the actual server-facing gateway) holds `.254`.

### 3.2 Router-to-Core Links (`/30`)

| Link | Router (`.1`) | Core (`.2`) |
| :--- | :--- | :--- |
| R-HER-1 ↔ CORE-1 | `10.10.1.1` | `10.10.1.2` |
| R-HER-1 ↔ CORE-2 | `10.10.2.1` | `10.10.2.2` |
| R-HER-2 ↔ CORE-1 | `10.10.3.1` | `10.10.3.2` |
| R-HER-2 ↔ CORE-2 | `10.10.4.1` | `10.10.4.2` |
| R-CART-1 ↔ CORE-1 | `10.10.5.1` | `10.10.5.2` |
| R-CART-1 ↔ CORE-2 | `10.10.6.1` | `10.10.6.2` |
| R-CART-2 ↔ CORE-1 | `10.10.7.1` | `10.10.7.2` |
| R-CART-2 ↔ CORE-2 | `10.10.8.1` | `10.10.8.2` |

### 3.3 Inter-Site WAN Links (`/30`)

| Link | Heredia IP | Cartago IP |
| :--- | :--- | :--- |
| R-HER-1 ↔ R-CART-1 | `10.0.1.1` | `10.0.1.2` |
| R-HER-1 ↔ R-CART-2 | `10.0.2.1` | `10.0.2.2` |
| R-HER-2 ↔ R-CART-1 | `10.0.3.1` | `10.0.3.2` |
| R-HER-2 ↔ R-CART-2 | `10.0.4.1` | `10.0.4.2` |

### 3.4 ISP Uplinks (`/30`)

| Site | Link | Router IP |
| :--- | :--- | :--- |
| Heredia | R-HER-1 → ISP-1 | `10.1.1.1` |
| Heredia | R-HER-1 → ISP-2 | `10.1.2.1` |
| Heredia | R-HER-2 → ISP-1 | `10.1.3.1` |
| Heredia | R-HER-2 → ISP-2 | `10.1.4.1` |
| Cartago | R-CART-1 → ISP-1 | `10.2.1.1` |
| Cartago | R-CART-1 → ISP-2 | `10.2.2.1` |
| Cartago | R-CART-2 → ISP-1 | `10.2.3.1` |
| Cartago | R-CART-2 → ISP-2 | `10.2.4.1` |

### 3.5 Internal Server Static Assignments

| Device | Heredia | Cartago | VLAN |
| :--- | :--- | :--- | :--- |
| SRV-INT-1 (DNS) | `192.168.30.11` | `192.168.130.11` | 30 |
| SRV-INT-2 (Monitoring / Secondary DNS) | `192.168.30.12` | `192.168.130.12` | 30 |
| PC-ADMIN | `192.168.10.11` | `192.168.110.11` | 10 |

---

## 4. Build Order

Configuration was executed bottom-up. Each layer depends on the previous one being correctly in place before proceeding:

1. VLAN creation across all 16 switches
2. Access and trunk port assignment
3. EtherChannel (LACP) between Core and Distribution
4. RSTP activation and root bridge priorities
5. SVI creation and IP routing on Core switches
6. Conversion of Core-to-Router ports to routed ports
7. Router interface configuration (ISP, Core, WAN)
8. OSPF configuration across all 8 Layer 3 devices
9. HSRP configuration for gateway redundancy
10. DHCP configuration on primary Core switches
11. Static IP and DNS service assignment on internal servers
12. Final verification and failover testing

---

## 5. VLAN Configuration

Applied identically across all 16 switches (Core, Distribution, and Access, both sites). VLANs must exist before port assignment:

```text
enable
configure terminal
!
vlan 10
 name Gestion
vlan 20
 name Clientes
vlan 30
 name Servidores_Internos
vlan 40
 name Almacenamiento
!
end
write memory

```

---

## 6. Access & Trunk Ports

### 6.1 Access Switches

Each Access switch connects to both Distribution switches (`Fa0/1` → DIST-1, `Fa0/2` → DIST-2) plus its assigned servers. Uplinks to Distribution are trunks; server-facing ports are access ports.

**SW-ACC-1** (Client servers 01–05, VLAN 20):

```text
enable
configure terminal
!
interface Fa0/1
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
interface Fa0/2
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
interface range Fa0/3-7
 switchport mode access
 switchport access vlan 20
!
end
write memory

```

**SW-ACC-2 and SW-ACC-3** (Client VLAN 20 + Internal Servers VLAN 30): identical to the above, with internal server ports added:

```text
interface range Fa0/8-9
 switchport mode access
 switchport access vlan 30

```

**SW-ACC-4** (Client VLAN 20 + PC-ADMIN VLAN 10):

```text
interface range Fa0/3-7
 switchport mode access
 switchport access vlan 20
!
interface Fa0/8
 switchport mode access
 switchport access vlan 10

```

### 6.2 Distribution Switches

All ports are trunks (Distribution only connects to other switches). `Fa0/1-4` face Access; `Fa0/5-6` and `Gi0/1-2` face the Core layer.

```text
enable
configure terminal
!
interface range Fa0/1-6
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
interface range Gi0/1-2
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
end
write memory

```

---

## 7. EtherChannel (LACP)

Each Core-to-Distribution pair aggregates two physical links into a single logical Port-channel via LACP, providing both load balancing and cable-level redundancy — both links carry traffic simultaneously, and if one fails, the other maintains the link without triggering RSTP reconvergence.

### Port-Channel Assignment

| Port-Channel | Link | Core Ports | Distribution Ports |
| :--- | :--- | :--- | :--- |
| Po1 | CORE-1 ↔ DIST-1 | `Gi1/0/4`, `Gi1/0/6` | `Gi0/1`, `Fa0/5` |
| Po2 | CORE-1 ↔ DIST-2 | `Gi1/0/5`, `Gi1/0/7` | `Gi0/1`, `Fa0/5` |
| Po3 | CORE-2 ↔ DIST-1 | `Gi1/0/4`, `Gi1/0/6` | `Gi0/2`, `Fa0/6` |
| Po4 | CORE-2 ↔ DIST-2 | `Gi1/0/5`, `Gi1/0/7` | `Gi0/2`, `Fa0/6` |

**On SW-CORE-1:**

```text
enable
configure terminal
!
interface range Gi1/0/4, Gi1/0/6
 channel-group 1 mode active
!
interface range Gi1/0/5, Gi1/0/7
 channel-group 2 mode active
!
interface Gi1/0/3
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
interface Port-channel1
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
interface Port-channel2
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40
!
end
write memory

```

> **Note**: On the Catalyst 3650, the `interface range Port-channel1-2` syntax is not valid; each Port-channel interface must be configured individually.

**On SW-CORE-2:**

```text
interface range Gi1/0/4, Gi1/0/6
 channel-group 3 mode active
!
interface range Gi1/0/5, Gi1/0/7
 channel-group 4 mode active
!
interface Port-channel3 / Port-channel4
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40

```

**On SW-DIST-1 (receiving end):**

```text
interface range Gi0/1, Fa0/5
 channel-group 1 mode active
!
interface range Gi0/2, Fa0/6
 channel-group 3 mode active
!
interface Port-channel1 / Port-channel3
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40

```

**On SW-DIST-2 (receiving end):**

```text
interface range Gi0/1, Fa0/5
 channel-group 2 mode active
!
interface range Gi0/2, Fa0/6
 channel-group 4 mode active
!
interface Port-channel2 / Port-channel4
 switchport mode trunk
 switchport trunk allowed vlan 10,20,30,40

```

**Verification**: `show etherchannel summary` — each Port-channel should report `(SU)`, and its member ports `(P)`.

---

## 8. RSTP (Rapid Spanning Tree)

RSTP prevents Layer 2 loops and provides fast convergence (1–2 seconds) on link failure. CORE-1 is fixed as the primary root bridge and CORE-2 as the secondary root, across all VLANs.

**On SW-CORE-1:**

```text
enable
configure terminal
!
spanning-tree mode rapid-pvst
spanning-tree vlan 10,20,30,40 priority 4096
!
end
write memory

```

**On SW-CORE-2:**

```text
spanning-tree mode rapid-pvst
spanning-tree vlan 10,20,30,40 priority 8192

```

**On all Distribution and Access switches:**

```text
spanning-tree mode rapid-pvst

```

**Verification**: `show spanning-tree` — the root bridge for VLANs 10–40 must be CORE-1 (priority `4096` + VLAN ID). On each Access switch, `Fa0/1` should report `Root FWD` and `Fa0/2` should report `Altn BLK` (standby block).

---

## 9. SVIs & IP Routing on Core Switches

Core switches operate at Layer 3. Each receives one Switched Virtual Interface (SVI) per VLAN, functioning as the subnet gateway. Routing is enabled via `ip routing`.

**SW-CORE-1 Heredia** (Core 2 uses `.2` instead of `.1`):

```text
enable
configure terminal
!
ip routing
!
interface Vlan10
 ip address 192.168.10.1 255.255.255.0
!
interface Vlan20
 ip address 192.168.20.1 255.255.255.0
!
interface Vlan30
 ip address 192.168.30.1 255.255.255.0
!
interface Vlan40
 ip address 192.168.40.1 255.255.255.0
!
end
write memory

```

> Cartago uses the `192.168.110–140.0/24` subnet range with an identical structure.

---

## 10. Core-to-Router Routed Ports

Core ports facing the routers are converted to routed ports (`no switchport`) with an IP address on the `/30` Router-Core subnets.

**SW-CORE-1 Heredia:**

```text
enable
configure terminal
!
interface Gi1/0/1
 no switchport
 ip address 10.10.1.2 255.255.255.252
!
interface Gi1/0/2
 no switchport
 ip address 10.10.3.2 255.255.255.252
!
end
write memory

```

**SW-CORE-2 Heredia:**

```text
interface Gi1/0/1
 no switchport
 ip address 10.10.2.2 255.255.255.252
!
interface Gi1/0/2
 no switchport
 ip address 10.10.4.2 255.255.255.252

```

> Cartago: CORE-1 uses `10.10.5.2` and `10.10.7.2`; CORE-2 uses `10.10.6.2` and `10.10.8.2`.

---

## 11. Router Interfaces

**Key technical constraint**: on the ISR 4331, the `Gi0/1/x` module ports are switchports (NIM-ES2 module) and do not accept IP addresses directly. The applied solution assigns each physical port to an internal router VLAN (`101`–`104`) and places the IP address on the corresponding VLAN interface instead.

| Internal VLAN | Physical Port | Destination |
| :--- | :--- | :--- |
| 101 | `Gi0/1/0` | CORE-1 |
| 102 | `Gi0/1/1` | CORE-2 |
| 103 | `Gi0/1/2` | WAN to remote site (link A) |
| 104 | `Gi0/1/3` | WAN to remote site (link B) |

**R-HER-1** (full example):

```text
enable
configure terminal
hostname R-HER-1
!
! --- ISP-facing interfaces (native routed ports) ---
interface Gi0/0/0
 ip address 10.1.1.1 255.255.255.252
 no shutdown
!
interface Gi0/0/1
 ip address 10.1.2.1 255.255.255.252
 no shutdown
!
! --- Switch module ports assigned to internal VLANs ---
interface Gi0/1/0
 switchport access vlan 101
!
interface Gi0/1/1
 switchport access vlan 102
!
interface Gi0/1/2
 switchport access vlan 103
!
interface Gi0/1/3
 switchport access vlan 104
!
! --- IP addresses on the VLAN interfaces ---
interface Vlan101
 ip address 10.10.1.1 255.255.255.252
 no shutdown
!
interface Vlan102
 ip address 10.10.2.1 255.255.255.252
 no shutdown
!
interface Vlan103
 ip address 10.0.1.1 255.255.255.252
 no shutdown
!
interface Vlan104
 ip address 10.0.2.1 255.255.255.252
 no shutdown
!
end
write memory

```

> The `%CDP-4-NATIVE_VLAN_MISMATCH` messages that appear during this configuration are cosmetic and do not affect the functionality of these point-to-point Layer 3 links.

### Equivalent Addressing for Remaining Routers

| Router | Vlan101 (CORE-1) | Vlan102 (CORE-2) | Vlan103 (WAN) | Vlan104 (WAN) |
| :--- | :--- | :--- | :--- | :--- |
| R-HER-1 | `10.10.1.1` | `10.10.2.1` | `10.0.1.1` | `10.0.2.1` |
| R-HER-2 | `10.10.3.1` | `10.10.4.1` | `10.0.3.1` | `10.0.4.1` |
| R-CART-1 | `10.10.5.1` | `10.10.6.1` | `10.0.1.2` | `10.0.3.2` |
| R-CART-2 | `10.10.7.1` | `10.10.8.1` | `10.0.2.2` | `10.0.4.2` |

> ISP-facing interfaces: R-HER-1 uses `10.1.1.1` / `10.1.2.1`; R-HER-2 uses `10.1.3.1` / `10.1.4.1`; R-CART-1 uses `10.2.1.1` / `10.2.2.1`; R-CART-2 uses `10.2.3.1` / `10.2.4.1`.

---

## 12. OSPF

OSPF process `1`, area `0`, is configured across all 8 Layer 3 devices (4 routers + 4 Core switches). It distributes routes for both sites and enables automated failover and ECMP load balancing across equal-cost paths.

| Device | Router ID |
| :--- | :--- |
| R-HER-1 | `1.1.1.1` |
| R-HER-2 | `2.2.2.2` |
| R-CART-1 | `3.3.3.3` |
| R-CART-2 | `4.4.4.4` |
| CORE-1 Heredia | `11.11.11.11` |
| CORE-2 Heredia | `12.12.12.12` |
| CORE-1 Cartago | `13.13.13.13` |
| CORE-2 Cartago | `14.14.14.14` |

**R-HER-1:**

```text
enable
configure terminal
!
router ospf 1
 router-id 1.1.1.1
 network 10.1.1.0 0.0.0.3 area 0
 network 10.1.2.0 0.0.0.3 area 0
 network 10.10.1.0 0.0.0.3 area 0
 network 10.10.2.0 0.0.0.3 area 0
 network 10.0.1.0 0.0.0.3 area 0
 network 10.0.2.0 0.0.0.3 area 0
!
end
write memory

```

**CORE-1 Heredia** (includes locally attached VLAN subnets):

```text
router ospf 1
 router-id 11.11.11.11
 network 10.10.1.0 0.0.0.3 area 0
 network 10.10.3.0 0.0.0.3 area 0
 network 192.168.10.0 0.0.0.255 area 0
 network 192.168.20.0 0.0.0.255 area 0
 network 192.168.30.0 0.0.0.255 area 0
 network 192.168.40.0 0.0.0.255 area 0

```

> Each device advertises only its directly connected networks. Cartago Core switches advertise the `192.168.110–140.0` subnet range.

**Verification**: `show ip ospf neighbor` (all adjacencies must report `FULL`) and `show ip route ospf` (routes to the remote site, with multiple equal-cost paths confirming ECMP).

---

## 13. HSRP (Gateway Redundancy)

HSRP eliminates the single point of failure at the gateway layer. Both Core switches share a virtual IP (`.254`) that servers use as their default gateway. CORE-1 is active (priority `110`); if it fails, CORE-2 assumes the virtual IP automatically. The `preempt` command allows CORE-1 to reclaim the active role upon reintegration (failback).

**SW-CORE-1 Heredia (active):**

```text
enable
configure terminal
!
interface Vlan10
 standby 10 ip 192.168.10.254
 standby 10 priority 110
 standby 10 preempt
!
interface Vlan20
 standby 20 ip 192.168.20.254
 standby 20 priority 110
 standby 20 preempt
!
interface Vlan30
 standby 30 ip 192.168.30.254
 standby 30 priority 110
 standby 30 preempt
!
interface Vlan40
 standby 40 ip 192.168.40.254
 standby 40 priority 110
 standby 40 preempt
!
end
write memory

```

**SW-CORE-2 Heredia (standby, no priority or preempt):**

```text
interface Vlan10
 standby 10 ip 192.168.10.254
!
interface Vlan20
 standby 20 ip 192.168.20.254
!
interface Vlan30
 standby 30 ip 192.168.30.254
!
interface Vlan40
 standby 40 ip 192.168.40.254

```

> Cartago uses virtual IPs `192.168.110.254`, `192.168.120.254`, `192.168.130.254`, and `192.168.140.254`.

**Verification**: `show standby brief` — CORE-1 must report `Active` and CORE-2 `Standby` across all four groups.

---

## 14. DHCP

DHCP is configured on the CORE-1 switch of each site (which functions as the gateway and observes VLAN broadcast traffic). Addresses reserved for infrastructure and static assignments are excluded. The gateway handed out to clients is the HSRP virtual IP (`.254`).

**SW-CORE-1 Heredia:**

```text
enable
configure terminal
!
ip dhcp excluded-address 192.168.10.1 192.168.10.20
ip dhcp excluded-address 192.168.20.1 192.168.20.10
ip dhcp excluded-address 192.168.30.1 192.168.30.20
ip dhcp excluded-address 192.168.40.1 192.168.40.10
!
ip dhcp pool VLAN10-HER
 network 192.168.10.0 255.255.255.0
 default-router 192.168.10.254
 dns-server 192.168.30.11
!
ip dhcp pool VLAN20-HER
 network 192.168.20.0 255.255.255.0
 default-router 192.168.20.254
 dns-server 192.168.30.11
!
ip dhcp pool VLAN30-HER
 network 192.168.30.0 255.255.255.0
 default-router 192.168.30.254
 dns-server 192.168.30.11
!
ip dhcp pool VLAN40-HER
 network 192.168.40.0 255.255.255.0
 default-router 192.168.40.254
 dns-server 192.168.30.11
!
end
write memory

```

> Cartago replicates this configuration with the `192.168.110–140.0` subnet range and DNS server `192.168.130.11`.

> [!NOTE]
> **Known Packet Tracer limitation**: the simulator supports only a single `dns-server` entry per DHCP pool. A production environment would hand out both a primary and secondary DNS server via DHCP options. Statically addressed devices in this topology do receive both a primary (`.11`) and secondary (`.12`) DNS server, as shown in Section 15.

---

## 15. Static IPs & DNS Service

Internal servers and PC-ADMIN receive static IP addresses (excluded from DHCP). They are configured with the HSRP gateway (`.254`) and primary/secondary DNS for automatic failover.

| Device | IP | Gateway | Primary DNS | Secondary DNS |
| :--- | :--- | :--- | :--- | :--- |
| SRV-INT-1 Heredia | `192.168.30.11` | `192.168.30.254` | `192.168.30.11` | `192.168.30.12` |
| SRV-INT-2 Heredia | `192.168.30.12` | `192.168.30.254` | `192.168.30.11` | `192.168.30.12` |
| PC-ADMIN Heredia | `192.168.10.11` | `192.168.10.254` | `192.168.30.11` | `192.168.30.12` |

To eliminate the DNS single point of failure, both internal servers run the DNS service (`Services → DNS → On`) with identical records. `SRV-INT-1` sits on Access Switch 2 and `SRV-INT-2` sits on Access Switch 3, so that the failure of a single Access switch does not leave the site without name resolution.

---

## 16. Final Verification

From a client server (`Desktop → Command Prompt`):

```text
ipconfig
-> IP in the .21+ range, gateway .254, DNS .11

ping 192.168.20.254   (HSRP virtual gateway)
ping 192.168.30.11    (DNS server, cross-VLAN)

```

**Inter-site test**: from a Heredia client, ping a Cartago client (e.g. `192.168.120.21`) to confirm OSPF is routing traffic across the full WAN mesh.

---

## 17. Verification Summary

| Check | Command | Expected Result |
| :--- | :--- | :--- |
| EtherChannel state | `show etherchannel summary` | Each Port-channel reports `(SU)`; member ports report `(P)`. |
| RSTP root bridge | `show spanning-tree` | CORE-1 is root for VLANs 10–40; Access `Fa0/1` is `Root FWD`, `Fa0/2` is `Altn BLK`. |
| OSPF adjacencies | `show ip ospf neighbor` | All adjacencies report `FULL`. |
| ECMP routing | `show ip route ospf` | Multiple equal-cost paths to the remote site. |
| HSRP state | `show standby brief` | CORE-1 `Active`, CORE-2 `Standby` across all four groups. |
| Client connectivity | `ipconfig`, `ping` | Correct DHCP lease, gateway reachable, DNS reachable across VLANs. |
| Inter-site routing | `ping` (cross-site) | Successful round trip via the WAN mesh. |

With these checks passing, the network topology is functionally complete: inter-VLAN and inter-site routing, gateway redundancy (HSRP), link load balancing and redundancy (EtherChannel), fast Layer 2 convergence (RSTP), and dynamic routing with automated failover (OSPF).
