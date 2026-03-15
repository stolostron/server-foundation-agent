# Deployment Guide

## Prerequisites

- Kubernetes cluster with [KubeOpenCode](https://kubeopencode.io) operator installed
- `kubectl` and `kustomize` CLI tools
- GitHub App credentials for the bot

## Platform

The resources in this directory (`Agent`, `Task`, `TaskTemplate`) are custom resources defined by [KubeOpenCode](https://github.com/kubeopencode/kubeopencode) — a Kubernetes-native platform for running AI agents. Standard Kubernetes resources (`CronJob`, `ServiceAccount`, `Role`, etc.) are used alongside them for scheduling and RBAC.

| Custom Resource | API Group | Description |
|-----------------|-----------|-------------|
| `Agent` | `kubeopencode.io/v1alpha1` | Declares an agent (identity, model, credentials, contexts) |
| `Task` | `kubeopencode.io/v1alpha1` | A unit of work assigned to an agent |
| `TaskTemplate` | `kubeopencode.io/v1alpha1` | Reusable task definition |

## Namespace

All resources are deployed to a single `server-foundation` namespace.

## Setup

### 1. Create secrets

```bash
cp deploy/secrets.example.yaml deploy/secrets.yaml
# Edit secrets.yaml with actual values
```

### 2. Deploy everything

```bash
kubectl apply -k deploy/
```

## Changing Resources

When renaming, adding, or removing any resource file under `deploy/`, always review `kustomization.yaml` to ensure all `resources:` entries match the actual filenames. Stale references will cause `kubectl apply -k` to fail.

## Manual Task Triggers

### Weekly PR Report

```bash
kubectl create job test-weekly-pr-report \
  --from=cronjob/weekly-pr-report-cron \
  -n server-foundation
```

### Ad-hoc Task

```bash
cat <<EOF | kubectl create -f -
apiVersion: kubeopencode.io/v1alpha1
kind: Task
metadata:
  generateName: adhoc-task-
  namespace: server-foundation
spec:
  agentRef:
    name: server-foundation-agent
  description: |
    <your task description here>
  contexts:
    - name: target-repo
      type: Git
      git:
        repository: https://github.com/org/repo.git
        ref: main
      mountPath: target
EOF
```

## Monitoring

```bash
# Watch tasks
kubectl get tasks -n server-foundation -w

# Check CronJob status
kubectl get cronjobs -n server-foundation

# View recent jobs
kubectl get jobs -n server-foundation --sort-by=.metadata.creationTimestamp
```
