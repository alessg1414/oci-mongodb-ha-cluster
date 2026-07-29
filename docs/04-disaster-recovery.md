# Disaster Recovery (DR) & Data Integrity Protocols

---

## 1. Overview & Business Continuity Objectives

This document establishes the operational procedures for **Disaster Recovery (DR)**, physical dataset backups, and point-in-time restoration for the **JobBridge** production database hosted on Oracle Cloud Infrastructure (OCI).

### Disaster Recovery Metrics
* **Recovery Point Objective (RPO)**: **RPO = 0** for node-level failovers via synchronous oplog replication. For catastrophically unrecoverable physical site/region failures, RPO is determined by the interval of scheduled logical/physical backups (e.g., maximum 24 hours).
* **Recovery Time Objective (RTO)**: **RTO < 30 seconds** for automated cluster leader election during single-node failure. **RTO < 2 hours** for full cold-start database restoration from off-site backup archives.

---

## 2. Production Dataset Scope

The Disaster Recovery plan encompasses the complete production MongoDB dataset for the JobBridge platform, consisting of **5 core application collections**:

| Collection Name | Purpose / Business Logic | Criticality |
| :--- | :--- | :--- |
| `users` | User profile data, authentication metadata, and role assignments. | High |
| `services` | Published service offerings, pricing structures, and domain categories. | High |
| `contracts` | Active and historical service agreements between clients and freelancers. | Critical |
| `messages` | Direct platform communications and interaction logs. | Medium |
| `ratings` | Service feedback scores and platform review histories. | Medium |

---

## 3. Backup & Archival Runbook

Database backups are generated using `mongodump` to capture binary BSON exports of the production collections along with their corresponding index definitions.

### Step 3.1: Logical Backup Execution
Run the backup script on the active Secondary node (`10.0.1.11`) to prevent resource contention or locking on the Primary write node:

```bash
#!/usr/bin/env bash

# Set backup parameters
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
BACKUP_DIR="/var/backups/mongodb/jobbridge_${TIMESTAMP}"
TARGET_DB="jobbridge"

# Ensure output directory exists
mkdir -p "${BACKUP_DIR}"

# Execute mongodump against the local Secondary instance
mongodump \
  --host="10.0.1.11:27017" \
  --db="${TARGET_DB}" \
  --out="${BACKUP_DIR}" \
  --gzip \
  --oplog

echo "Backup completed successfully at ${BACKUP_DIR}"

```

### Step 3.2: Archive Packaging & Off-site Storage

Compress the backup directory and transfer it to secure OCI Object Storage or an off-site repository:

```bash
# Package archive
tar -czvf "jobbridge_backup_${TIMESTAMP}.tar.gz" -C "/var/backups/mongodb" "jobbridge_${TIMESTAMP}"

# Transfer to OCI Object Storage (Example via OCI CLI)
oci os object put \
  -bn jobbridge-database-backups \
  --file "jobbridge_backup_${TIMESTAMP}.tar.gz" \
  --name "backups/jobbridge_backup_${TIMESTAMP}.tar.gz"

```

---

## 4. Cold Restoration & Disaster Recovery Runbook

In the event of total cluster failure or data corruption, follow this runbook to restore dataset integrity.

### Step 4.1: Retrieve and Unpack Archive

Fetch the target backup archive from off-site storage to the target recovery host:

```bash
# Uncompress the backup archive
tar -xzvf jobbridge_backup_YYYYMMDD_HHMMSS.tar.gz -C /tmp/restore_stage/

```

### Step 4.2: Execute Data Restoration

Use `mongorestore` to rebuild the collections and indexes on the active Primary node:

```bash
mongorestore \
  --host="10.0.1.10:27017" \
  --db="jobbridge" \
  --drop \
  --gzip \
  --dir="/tmp/restore_stage/jobbridge_YYYYMMDD_HHMMSS/jobbridge"

```

> **Note**: The `--drop` flag removes existing collections prior to restoration, ensuring no duplicate key conflicts occur during point-in-time recovery.

---

## 5. Post-Restoration Data Integrity Audit

Following any DR restoration event, execute the following validation steps to confirm complete data parity across all 5 collections:

### Step 5.1: Collection Document Verification

Run the verification shell command to check record counts against expected baselines:

```bash
mongosh --quiet --host 10.0.1.10:27017/jobbridge --eval "
  const collections = ['users', 'services', 'contracts', 'messages', 'ratings'];
  collections.forEach(col => {
    print(col + ' count: ' + db.getCollection(col).countDocuments());
  });
"

```

### Step 5.2: Re-establish Replication Synchronization

Ensure that once the Primary host is restored and validated, Secondary nodes sync from the restored Primary without replication errors:

```bash
mongosh --quiet --host 10.0.1.11:27017 --eval "rs.printReplicationInfo()"

```

**Expected Result**: Secondary oplog position matches Primary oplog position, indicating zero replication lag.
