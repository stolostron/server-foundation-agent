---
name: acm-tools:uninstall-acm
description: Uninstall ACM (Advanced Cluster Management) from an OpenShift cluster. Checks for managed clusters (excluding local-cluster), optionally deprovisions Hive-managed clusters, deletes MultiClusterHub CR and waits for complete removal, then cleans up Subscription and ClusterServiceVersion. Use when removing ACM from an OCP cluster.
---

# Uninstall ACM Skill

Uninstall ACM from an OpenShift cluster with managed cluster cleanup.

## Usage

```bash
./scripts/uninstall-acm.sh [options]
```

### Options

| Flag | Description | Example |
|------|-------------|---------|
| `--kubeconfig PATH` | Path to kubeconfig file | `--kubeconfig ~/.kube/config` |
| `--skip-cluster-check` | Skip managed cluster check | `--skip-cluster-check` |
| `--deprovision-all` | Deprovision all Hive clusters without prompting | `--deprovision-all` |
| `--force` | Skip all confirmation prompts | `--force` |

### Uninstall Steps

1. **Check managed clusters**: List all managed clusters excluding `local-cluster`. If Hive-provisioned clusters exist, prompt user for deprovisioning.
2. **Delete MultiClusterHub**: Delete the MCH CR and wait for complete removal.
3. **Cleanup operators**: Delete ACM Subscription and ClusterServiceVersion.

### Examples

```bash
# Interactive uninstall
./scripts/uninstall-acm.sh

# Uninstall with force (no prompts)
./scripts/uninstall-acm.sh --force

# Deprovision all Hive clusters and uninstall
./scripts/uninstall-acm.sh --deprovision-all
```
