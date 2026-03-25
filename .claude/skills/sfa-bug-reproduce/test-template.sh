#!/bin/bash
# Test Script Template for Bug Reproduction
# Exit 0 = bug NOT reproduced (test passed)
# Exit non-zero = bug reproduced (test failed)

set -e  # Exit on any error (this means bug is reproduced)

echo "=== Bug Reproduction Test ==="
echo "Testing: [Bug Summary]"
echo ""

# Step 1: Setup test data
echo "Step 1: Creating test resources..."
kubectl create namespace test-bug-reproduction || true

# Example: Create a ManagedCluster CR
cat <<EOF | kubectl apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: test-cluster
spec:
  hubAcceptsClient: true
EOF

echo "✓ Test cluster created"
echo ""

# Step 2: Wait for expected state
echo "Step 2: Waiting for cluster to be accepted..."
kubectl wait --for=condition=HubAcceptedManagedCluster managedcluster/test-cluster --timeout=60s

echo "✓ Cluster accepted"
echo ""

# Step 3: Trigger the bug scenario
echo "Step 3: Executing bug trigger..."

# Example: Modify annotation that should trigger a reconcile
kubectl annotate managedcluster test-cluster \
  cluster.open-cluster-management.io/hosting-cluster-name=wrong-name

echo "✓ Annotation updated"
echo ""

# Step 4: Verify the bug occurs (or doesn't occur)
echo "Step 4: Checking for bug symptoms..."

# Example: Check if addon status is updated (ACM-30940)
# If the bug is present, the addon will NOT update, so we expect this to fail
sleep 10  # Give time for reconciliation

# Check addon status - if it's still in bad state, bug is reproduced
ADDON_STATUS=$(kubectl get managedclusteraddon -n test-cluster test-addon -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "NotFound")

if [[ "$ADDON_STATUS" != "True" ]]; then
  echo "❌ Bug reproduced: Addon status is $ADDON_STATUS (expected: True)"
  echo "   The addon did not update after annotation change"
  exit 1  # Bug reproduced
fi

echo "✓ Addon status is healthy"
echo ""

# Cleanup
echo "Cleanup: Removing test resources..."
kubectl delete namespace test-bug-reproduction --ignore-not-found

echo ""
echo "=== Test Result: PASS ==="
echo "Bug NOT reproduced - addon updated correctly after annotation change"

exit 0  # Bug not reproduced
