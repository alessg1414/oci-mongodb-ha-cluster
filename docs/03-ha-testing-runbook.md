# High Availability (HA) Testing Runbook

---

## 1. Overview & Test Objectives

This runbook documents the formal testing procedures used to validate the **High Availability (HA)** and **Failover Capabilities** of the `rsJobBridge` MongoDB Replica Set hosted on Oracle Cloud Infrastructure (OCI).

### Test Objectives
1. **Primary Failure Simulation**: Verify that the cluster detects primary node unavailability within the configured heartbeat timeout (10 seconds).
2. **Automated Consensus & Election**: Validate that the surviving Secondary (`10.0.1.11:27017`) and Arbiter (`10.0.1.11:27018`) form a valid quorum (2 out of 3 votes) and promote the Secondary to Primary.
3. **Write Availability Post-Failover**: Ensure client applications can execute write transactions on the newly promoted Primary without data corruption.
4. **Node Reintegration**: Confirm that when the failed node returns to service, it automatically re-joins as a Secondary and synchronizes missing oplog transactions in the background.

---

## 2. Environment Prerequisites & Baseline Setup

Before initiating failover testing, ensure the cluster is in a healthy, fully converged baseline state.

### Step 2.1: Verify Initial Cluster Topology
Execute the following query from any host with network access to the cluster:

```bash
mongosh --quiet --host 10.0.1.10:27017 --eval "
  rs.status().members.map(m => ({
    id: m._id,
    name: m.name,
    state: m.stateStr,
    health: m.health
  }))
"

```

**Expected Baseline State**:

* `10.0.1.10:27017`: `PRIMARY` (Health: `1`)
* `10.0.1.11:27017`: `SECONDARY` (Health: `1`)
* `10.0.1.11:27018`: `ARBITER` (Health: `1`)

---

## 3. Automated Failover Test Execution

The failover test suite can be executed automatically using the provided verification script `scripts/test-failover.sh` or performed manually step-by-step.

### Option A: Executing via Automated Test Script

Run the script from your management machine or bastion host:

```bash
chmod +x scripts/test-failover.sh
./scripts/test-failover.sh

```

### Option B: Manual Execution Steps

#### Step 1: Insert Pre-Failover Canary Document

Insert a record into the primary database to establish a pre-disruption baseline:

```bash
mongosh --quiet --host 10.0.1.10:27017/jobbridge --eval "
  db.ha_failover_test.insertOne({
    timestamp: new Date(),
    event: 'pre_failover_validation',
    status: 'success'
  })
"

```

#### Step 2: Forcefully Terminate Primary Service

Simulate an abrupt operating system or daemon failure by stopping the MongoDB service on `VM1` (`10.0.1.10`):

```bash
ssh ubuntu@10.0.1.10 "sudo systemctl stop mongod"

```

#### Step 3: Monitor Leader Election Status

Wait 10 seconds for heartbeat failure detection and consensus voting. Check the cluster state from `VM2` (`10.0.1.11`):

```bash
mongosh --quiet --host 10.0.1.11:27017 --eval "db.isMaster().primary"

```

**Expected Result**: The query returns `10.0.1.11:27017`, confirming `VM2` has been promoted to **Primary**.

#### Step 4: Validate Write Availability Post-Failover

Execute a write transaction against the newly promoted Primary:

```bash
mongosh --quiet --host 10.0.1.11:27017/jobbridge --eval "
  db.ha_failover_test.insertOne({
    timestamp: new Date(),
    event: 'post_failover_validation',
    status: 'success'
  })
"

```

**Expected Result**: Document insertion completes with `acknowledged: true`.

#### Step 5: Reintegrate Original Node

Restart the `mongod` service on `VM1` (`10.0.1.10`):

```bash
ssh ubuntu@10.0.1.10 "sudo systemctl start mongod"

```

Wait 5–10 seconds for background oplog synchronization, then verify the final member states:

```bash
mongosh --quiet --host 10.0.1.11:27017 --eval "
  rs.status().members.map(m => ({
    name: m.name,
    state: m.stateStr
  }))
"

```

**Expected Result**: `10.0.1.10:27017` transitions to **`SECONDARY`** without requiring a cluster restart.

---

## 4. Test Verification Matrix & Results

| Test ID | Test Scenario | Action Executed | Observed Result | RTO / Recovery Status | Status |
| --- | --- | --- | --- | --- | --- |
| **HA-01** | **Primary Daemon Termination** | Stopped `mongod` process on `10.0.1.10`. | Quorum loss detected. `10.0.1.11:27017` elected Primary within 12 seconds. | **< 15 Seconds** | **PASSED** |
| **HA-02** | **Post-Failover Write Availability** | Inserted test document into promoted Primary (`10.0.1.11`). | Write accepted and committed to oplog instantly. | **Instantaneous** | **PASSED** |
| **HA-03** | **Node Reintegration & Sync** | Restarted `mongod` process on `10.0.1.10`. | Node rejoined as `SECONDARY` and caught up via oplog stream. | **Automated Background Sync** | **PASSED** |
| **HA-04** | **Data Parity Audit** | Compared document counts across nodes post-sync. | Identical collection document counts across all data nodes. | **Zero Data Loss (RPO = 0)** | **PASSED** |
