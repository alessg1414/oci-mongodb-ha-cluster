#!/usr/bin/env bash

# ==============================================================================
# Failover & High Availability Verification Script
# Cluster: rsJobBridge
# ==============================================================================

set -euo pipefail

PRIMARY_IP="10.0.1.10"
SECONDARY_IP="10.0.1.11"
PORT="27017"
DB_NAME="jobbridge"
TEST_COLLECTION="ha_failover_test"

# Color Codes for Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=================================================="
echo " Starting High Availability & Failover Test Workflow"
echo "=================================================="

# 1. Verify Initial Cluster State
log_info "Step 1: Checking current Replica Set Primary node..."
CURRENT_PRIMARY=$(mongosh --quiet --host "${PRIMARY_IP}:${PORT}" --eval "db.isMaster().primary")

log_info "Current Active Primary Node: ${CURRENT_PRIMARY}"

if [[ "$CURRENT_PRIMARY" != "${PRIMARY_IP}:${PORT}" ]]; then
    log_warn "Primary is not on default node (${PRIMARY_IP}:${PORT}). Proceeding with current topology."
fi

# 2. Perform Pre-Failover Write
log_info "Step 2: Executing test write to primary database..."
mongosh --quiet --host "${CURRENT_PRIMARY}/${DB_NAME}" --eval "
  db.${TEST_COLLECTION}.insertOne({
    timestamp: new Date(),
    event: 'pre_failover_validation',
    status: 'success'
  })
" > /dev/null
log_info "Pre-failover document written successfully."

# 3. Simulate Primary Failure
log_info "Step 3: Simulating Primary Node Failure (Stopping mongod on ${PRIMARY_IP})..."
ssh -o StrictHostKeyChecking=no ubuntu@"${PRIMARY_IP}" "sudo systemctl stop mongod" || true

log_warn "Primary node shut down. Waiting 10 seconds for leader election and quorum convergence..."
sleep 10

# 4. Validate Secondary Promotion
log_info "Step 4: Querying target Secondary (${SECONDARY_IP}:${PORT}) for promoted status..."
NEW_PRIMARY=$(mongosh --quiet --host "${SECONDARY_IP}:${PORT}" --eval "db.isMaster().primary" || true)

log_info "Newly Promoted Primary Node: ${NEW_PRIMARY}"

if [[ "$NEW_PRIMARY" == "${SECONDARY_IP}:${PORT}" ]]; then
    log_info "SUCCESS: Automatic failover detected! Secondary node successfully promoted to Primary."
else
    log_error "FAIL: Secondary node was not promoted. Current state: ${NEW_PRIMARY}"
    exit 1
fi

# 5. Perform Post-Failover Write Verification
log_info "Step 5: Testing write availability on newly promoted Primary..."
mongosh --quiet --host "${NEW_PRIMARY}/${DB_NAME}" --eval "
  db.${TEST_COLLECTION}.insertOne({
    timestamp: new Date(),
    event: 'post_failover_validation',
    status: 'success'
  })
" > /dev/null
log_info "Post-failover document written successfully."

# 6. Reintegrate Original Primary
log_info "Step 6: Reintegrating original node (${PRIMARY_IP})..."
ssh -o StrictHostKeyChecking=no ubuntu@"${PRIMARY_IP}" "sudo systemctl start mongod"

log_info "Waiting 10 seconds for background oplog synchronization..."
sleep 10

# 7. Final Status Report
log_info "Step 7: Fetching final cluster status..."
mongosh --quiet --host "${SECONDARY_IP}:${PORT}" --eval "rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))"

echo "=================================================="
echo -e "${GREEN}HA Failover & Recovery Test Completed Successfully!${NC}"
echo "=================================================="