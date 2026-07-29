/**
 * MongoDB Replica Set Initialization Script
 * Target Cluster: rsJobBridge
 * 
 * Usage:
 * Execute via mongosh on the designated primary host (node1-active):
 *   mongosh mongodb://10.0.1.10:27017 init-replica-set.js
 */

const replicaSetConfig = {
  _id: "rsJobBridge",
  members: [
    {
      _id: 0,
      host: "10.0.1.10:27017",
      priority: 2,
      votes: 1
    },
    {
      _id: 1,
      host: "10.0.1.11:27017",
      priority: 1,
      votes: 1
    },
    {
      _id: 2,
      host: "10.0.1.11:27018",
      arbiterOnly: true,
      votes: 1
    }
  ]
};

print("==================================================");
print(" Initiating MongoDB Replica Set: rsJobBridge");
print("==================================================");

try {
  const initResult = rs.initiate(replicaSetConfig);
  printjson(initResult);

  if (initResult.ok === 1) {
    print("\n[SUCCESS] Replica set configuration applied successfully.");
    print("[INFO] Waiting for node election and convergence...");
    
    // Wait for cluster stabilization
    sleep(5000);
    
    print("\n==================================================");
    print(" Cluster Status Summary");
    print("==================================================");
    printjson(rs.status());
  } else {
    print("\n[ERROR] Failed to initiate replica set.");
  }
} catch (error) {
  print("\n[EXCEPTION] Error during replica set initiation:");
  print(error);
}