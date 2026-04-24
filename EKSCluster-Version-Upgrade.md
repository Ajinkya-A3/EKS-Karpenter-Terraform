# EKS Cluster Version Upgrade Runbook

> **Scope:** Covers Terraform-managed EKS clusters with managed node groups, EKS addons, and Karpenter node pools.  
> **Rule:** Always upgrade **one minor version at a time** — 1.29 → 1.30 → 1.31. Never skip.

---

## Table of Contents

1. [Pre-Upgrade Checklist](#1-pre-upgrade-checklist)
2. [Step 1 — Upgrade Control Plane](#2-step-1--upgrade-control-plane)
3. [Step 2 — Upgrade Managed Node Group](#3-step-2--upgrade-managed-node-group)
4. [Step 3 — Upgrade EKS Addons](#4-step-3--upgrade-eks-addons)
5. [Step 4 — Upgrade Karpenter Node Pools](#5-step-4--upgrade-karpenter-node-pools)
6. [Step 5 — Post-Upgrade Validation](#6-step-5--post-upgrade-validation)
7. [Workload Interruption Prevention](#7-workload-interruption-prevention)
8. [Rollback Plan](#8-rollback-plan)
9. [Quick Reference — Version Commands](#9-quick-reference--version-commands)

---

## 1. Pre-Upgrade Checklist

Complete every item before touching any Terraform or kubectl command.

### 1.1 Check Current Versions

```bash
# Current control plane version
aws eks describe-cluster \
  --name <cluster-name> \
  --query "cluster.version" \
  --output text

# Current node group AMI / kubelet version
aws eks describe-nodegroup \
  --cluster-name <cluster-name> \
  --nodegroup-name <nodegroup-name> \
  --query "nodegroup.releaseVersion" \
  --output text

# All nodes and their kubelet versions
kubectl get nodes -o wide

# All addon versions currently installed
aws eks list-addons --cluster-name <cluster-name>
aws eks describe-addon \
  --cluster-name <cluster-name> \
  --addon-name coredns \
  --query "addon.addonVersion"
```

### 1.2 Find the Target Addon Versions

```bash
# METHOD 1 — AWS CLI (recommended, most accurate)
# Lists all addon versions compatible with your TARGET Kubernetes version
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --query 'addons[*].{Addon:addonName, DefaultVersion:addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]}' \
  --output table

# For a specific addon
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --addon-name coredns \
  --query 'addons[0].addonVersions[*].addonVersion' \
  --output table

# METHOD 2 — eksctl (human-friendly output)
eksctl utils describe-addon-versions \
  --kubernetes-version 1.32 \
  --name coredns

# All addons at once via eksctl
eksctl utils describe-addon-versions \
  --kubernetes-version 1.32
```

### 1.3 Check Karpenter Compatibility

```bash
# Check current Karpenter version installed
helm list -n kube-system | grep karpenter

# Check what Karpenter version supports your target K8s version
# https://karpenter.sh/docs/upgrading/compatibility/
# Always verify against the official compatibility matrix
```

### 1.4 Verify Workload Health

```bash
# All pods should be Running or Completed — fix any CrashLoopBackOff before upgrading
kubectl get pods --all-namespaces | grep -v "Running\|Completed"

# Check PodDisruptionBudgets — understand what's protected
kubectl get pdb --all-namespaces

# Check Deployments for replica count — single replica workloads will have downtime
kubectl get deployments --all-namespaces | awk '$3 == 1 {print}'

# Ensure no nodes are already in NotReady state
kubectl get nodes | grep -v Ready
```

### 1.5 Backup

```bash
# Backup all cluster manifests (optional but recommended)
kubectl get all --all-namespaces -o yaml > cluster-backup-$(date +%F).yaml

# Update your kubeconfig
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

---

## 2. Step 1 — Upgrade Control Plane

### 2.1 Update the Variable

In your `terraform.tfvars` (or wherever `cluster_version` is set):

```hcl
# Before
cluster_version = "1.31"

# After
cluster_version = "1.32"
```

### 2.2 Plan and Apply — Control Plane Only

```bash
# Always plan first to confirm ONLY the cluster resource changes
terraform plan -target=aws_eks_cluster.eks

# Apply ONLY the control plane — do not apply everything at once
terraform apply -target=aws_eks_cluster.eks
```

> ⏱ **EKS control plane upgrades take 10–20 minutes.** The API server will be briefly unavailable (~30 seconds) during the transition. `kubectl` commands may fail during this window — this is normal.

### 2.3 Verify Control Plane

```bash
# Confirm the control plane is on the new version
aws eks describe-cluster \
  --name <cluster-name> \
  --query "cluster.{Version:version, Status:status}" \
  --output table

# Should show: ACTIVE + new version
kubectl version --short
```

> ⚠️ At this point your nodes are still on the OLD version — this is fine. EKS supports nodes one minor version behind the control plane. **Do not skip to addons — upgrade nodes next.**

---

## 3. Step 2 — Upgrade Managed Node Group

### 3.1 Confirm Node Group Config Has These Fields

Your `aws_eks_node_group` resource must have:

```hcl
resource "aws_eks_node_group" "ondemand-node" {
  # ... existing config ...

  version              = var.cluster_version  # ties node AMI to control plane version
  force_update_version = true                 # forces rolling update when version changes

  update_config {
    max_unavailable = 1  # only 1 node replaced at a time — safe for production
  }

  lifecycle {
    ignore_changes = [
      scaling_config[0].desired_size  # prevents Terraform fighting autoscaler
    ]
  }
}
```

### 3.2 Apply Node Group Upgrade

```bash
# Plan to confirm what changes (should show AMI version update)
terraform plan -target=aws_eks_node_group.ondemand-node

# Apply the rolling node update
terraform apply -target=aws_eks_node_group.ondemand-node
```

### 3.3 What Happens During Node Group Upgrade

AWS managed node groups handle this **automatically** in order:

```
1. New node launched with updated AMI (kubelet 1.32)
2. Old node cordoned  → no new pods scheduled on it
3. Old node drained   → pods evicted gracefully (respects PDBs)
4. Old node terminated
5. Repeat for next node (max_unavailable = 1 means one at a time)
```

> You do NOT need to manually cordon or drain nodes. AWS does it.

### 3.4 Monitor the Rolling Update

```bash
# Watch nodes transition (run in a separate terminal)
watch -n 5 kubectl get nodes

# Watch pods reschedule during drain
watch -n 5 kubectl get pods --all-namespaces

# Check node group update status
aws eks describe-nodegroup \
  --cluster-name <cluster-name> \
  --nodegroup-name <nodegroup-name> \
  --query "nodegroup.{Status:status, Version:version, ReleaseVersion:releaseVersion}"
```

> ⏱ **Node group rolling update:** ~5–10 minutes per node depending on workload drain time.

### 3.5 Verify Node Group

```bash
# All nodes should now show the new version
kubectl get nodes -o wide

# Confirm kubelet version matches control plane
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

---

## 4. Step 3 — Upgrade EKS Addons

**Always upgrade addons AFTER the node group.** Some addons (like `aws-ebs-csi-driver`) need nodes running to schedule their pods.

### 4.1 Find the Right Addon Versions for Target K8s Version

```bash
# Get the DEFAULT (recommended) version per addon for target version
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --query 'addons[*].{
    Name: addonName,
    Default: addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0],
    Latest: addonVersions[0].addonVersion
  }' \
  --output table

# Get ALL available versions for a specific addon
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --addon-name kube-proxy \
  --query 'addons[0].addonVersions[*].{Version:addonVersion,Default:compatibilities[0].defaultVersion}' \
  --output table

# Using eksctl for friendlier output
eksctl utils describe-addon-versions \
  --kubernetes-version 1.32 \
  --name kube-proxy

eksctl utils describe-addon-versions \
  --kubernetes-version 1.32 \
  --name coredns

eksctl utils describe-addon-versions \
  --kubernetes-version 1.32 \
  --name vpc-cni

eksctl utils describe-addon-versions \
  --kubernetes-version 1.32 \
  --name aws-ebs-csi-driver
```

### 4.2 Update Addon Versions in Terraform

Update your `addons` variable with versions found above:

```hcl
# In terraform.tfvars or variables.tf
addons = [
  {
    name    = "coredns"
    version = "v1.11.4-eksbuild.2"   # ← replace with output from step 4.1
  },
  {
    name    = "kube-proxy"
    version = "v1.32.3-eksbuild.2"   # ← replace with output from step 4.1
  },
  {
    name    = "vpc-cni"
    version = "v1.19.3-eksbuild.1"   # ← replace with output from step 4.1
  },
  {
    name    = "aws-ebs-csi-driver"
    version = "v1.40.0-eksbuild.1"   # ← replace with output from step 4.1
  }
]
```

### 4.3 Apply Addon Upgrades

```bash
terraform plan -target=aws_eks_addon.eks-addons
terraform apply -target=aws_eks_addon.eks-addons
```

### 4.4 Verify Addons

```bash
# All addons should show ACTIVE status
aws eks list-addons --cluster-name <cluster-name> --output table

# Verify each addon is healthy
aws eks describe-addon \
  --cluster-name <cluster-name> \
  --addon-name coredns \
  --query "addon.{Status:status,Version:addonVersion}"

# Verify addon pods are running
kubectl get pods -n kube-system
```

---

## 5. Step 4 — Upgrade Karpenter Node Pools

### 5.1 Understand What Happens to Karpenter Nodes

Karpenter nodes are **not automatically upgraded** when you upgrade EKS. They continue running their old kubelet version until:

- They naturally expire (per `expireAfter` in your NodePool), **or**
- You force a replacement via an `EC2NodeClass` annotation change

```
Control Plane      → 1.32  ✅ (Terraform)
Managed Node Group → 1.32  ✅ (Terraform, rolling)
Karpenter nodes    → 1.31  ⚠️  still on old kubelet — YOU must handle
```

### 5.2 Is It Safe to Let Karpenter Nodes Expire Naturally?

| NodePool | expireAfter | Safe to Let Expire? | Reason |
|---|---|---|---|
| spot-arm64 | 168h (7 days) | ✅ Usually fine | Replaced within a week |
| spot-amd64 | 168h (7 days) | ✅ Usually fine | Replaced within a week |
| ondemand-arm64 | 720h (30 days) | ⚠️ Risky | 30 days is too long if you upgrade frequently |
| ondemand-amd64 | 720h (30 days) | ⚠️ Risky | Same — and these run critical workloads |

**The key risk:** If you do another K8s upgrade (e.g., 1.32 → 1.33) before the 30-day nodes expire from the 1.31 → 1.32 upgrade, those nodes would be **two minor versions behind** — which is outside the supported compatibility window.

**Recommendation:**
- Spot pools (7 days): Let expire naturally — low risk
- OnDemand pools (30 days): Force replace — too long to leave uncontrolled

### 5.3 Option A — Let Expire Naturally (Spot Pools Only)

No action required. Karpenter will:
1. Detect the node has exceeded `expireAfter`
2. Launch a replacement node (picks up new AMI automatically via `al2023@latest`)
3. Cordon + drain the old node gracefully
4. Terminate the old node

Your workloads are live-migrated to the new node during this process.

### 5.4 Option B — Force Replace via EC2NodeClass Annotation (Recommended for OnDemand)

Add or increment an annotation in your `EC2NodeClass` Terraform resource:

```hcl
resource "kubectl_manifest" "karpenter_ec2_node_class_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
      annotations:
        # Increment this on every EKS version upgrade to trigger
        # Karpenter to replace ALL nodes from this NodeClass
        upgrade-revision: "2"        # ← was "1", now bump to "2"
    spec:
      # ... rest of config unchanged ...
  YAML
}
```

```bash
# Apply the annotation change
terraform apply -target=kubectl_manifest.karpenter_ec2_node_class_default
```

**What Karpenter does when it detects the annotation change:**

```
1. Marks all nodes from this NodeClass as "drifted"
2. For each drifted node:
   a. Launches a replacement node first (new AMI, new kubelet)
   b. Waits for replacement node to be Ready
   c. Cordons the old node
   d. Drains pods gracefully (respects PDBs and terminationGracePeriodSeconds)
   e. Terminates the old node
3. Repeats across all NodePools using this NodeClass
```

> Karpenter respects your PodDisruptionBudgets during this process. Pods with PDBs will not be evicted if it would violate the budget.

### 5.5 Monitor Karpenter Node Replacement

```bash
# Watch Karpenter logs for drift/replacement events
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --follow

# Watch nodes being replaced in real time
watch -n 5 kubectl get nodes -L karpenter.sh/nodepool,kubernetes.io/arch

# Check which nodes are drifted
kubectl get nodes -o json | jq '.items[] | select(.metadata.annotations["karpenter.sh/disruption-reason"] != null) | {name: .metadata.name, reason: .metadata.annotations["karpenter.sh/disruption-reason"]}'

# Watch pods rescheduling
watch -n 5 kubectl get pods --all-namespaces --field-selector=status.phase!=Running
```

### 5.6 Upgrade Karpenter Itself (Helm)

Karpenter has its own compatibility matrix with Kubernetes versions. After upgrading the control plane, upgrade Karpenter:

```bash
# Check current Karpenter version
helm list -n kube-system | grep karpenter

# Check compatibility: https://karpenter.sh/docs/upgrading/compatibility/
# Then update the version in your Helm release Terraform resource

# Example if managing via Helm CLI
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.3.3 \           # ← version compatible with your new K8s version
  --namespace kube-system \
  --reuse-values
```

---

## 6. Step 5 — Post-Upgrade Validation

Run these after all four steps are complete.

```bash
# 1. All nodes on correct version
kubectl get nodes -o wide

# 2. All pods healthy
kubectl get pods --all-namespaces | grep -v "Running\|Completed\|Succeeded"

# 3. Control plane version matches nodes
kubectl version

# 4. Addons all ACTIVE
aws eks list-addons --cluster-name <cluster-name> --output table

# 5. CoreDNS resolving correctly
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it \
  -- nslookup kubernetes.default

# 6. EBS volumes still working (if using EBS CSI)
kubectl get storageclass
kubectl get pv

# 7. Karpenter nodes on new version
kubectl get nodes -L karpenter.sh/nodepool \
  -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,POOL:.metadata.labels.karpenter\.sh/nodepool'

# 8. No PDB violations
kubectl get pdb --all-namespaces
```

---

## 7. Workload Interruption Prevention

Follow these practices to ensure zero (or minimal) workload disruption during upgrades.

### 7.1 PodDisruptionBudgets — Most Important

Every production Deployment should have a PDB. Without one, the node drain process can evict all pods simultaneously.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
  namespace: my-app
spec:
  minAvailable: 1          # at least 1 pod must stay running during drain
  # OR
  # maxUnavailable: 1      # at most 1 pod can be down at once
  selector:
    matchLabels:
      app: my-app
```

```bash
# Check which Deployments have NO PDB (these are at risk)
kubectl get deployments --all-namespaces -o json | \
  jq -r '.items[] | select(.spec.replicas > 0) | "\(.metadata.namespace)/\(.metadata.name)"' | \
  while read dep; do
    ns=$(echo $dep | cut -d/ -f1)
    name=$(echo $dep | cut -d/ -f2)
    pdbs=$(kubectl get pdb -n $ns --selector=$(kubectl get deploy $name -n $ns -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries[] | "\(.key)=\(.value)"' | head -1) 2>/dev/null | grep -v NAME | wc -l)
    if [ "$pdbs" -eq 0 ]; then echo "NO PDB: $dep"; fi
  done
```

### 7.2 Multiple Replicas

Single-replica Deployments will have downtime during node drain regardless of PDBs.

```bash
# Find single-replica Deployments in non-system namespaces
kubectl get deployments --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas' | \
  awk '$3 == 1 && $1 != "kube-system"'
```

Scale to at least 2 replicas before upgrading any production workload's node.

### 7.3 Pod Anti-Affinity

Ensure replicas spread across nodes so a single node drain doesn't take down all replicas:

```yaml
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app: my-app
            topologyKey: kubernetes.io/hostname
```

### 7.4 Proper Termination Handling

Ensure your app handles SIGTERM gracefully and completes in-flight requests:

```yaml
spec:
  terminationGracePeriodSeconds: 60   # give app 60s to finish requests
  containers:
    - name: my-app
      lifecycle:
        preStop:
          exec:
            command: ["/bin/sh", "-c", "sleep 5"]  # delay to let LB drain
```

### 7.5 Resource Requests and Limits

Nodes can only be drained if pods can be rescheduled elsewhere. Pods without resource requests may fail to schedule on new nodes during high utilization:

```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

---

## 8. Rollback Plan

EKS control plane **cannot be downgraded**. Prevention is the only option.

| Scenario | Action |
|---|---|
| Control plane stuck in UPDATING | Wait — AWS will retry or fail the update cleanly |
| Node group stuck draining | Check if a pod is blocking drain: `kubectl describe node <node>` |
| Pod refusing to evict | Check PDB: `kubectl get pdb -A`; temporarily reduce `minAvailable` if safe |
| Addon update fails | Revert addon version in Terraform and reapply |
| Karpenter nodes misbehaving | Revert `upgrade-revision` annotation; nodes will stop being replaced |

```bash
# If a node is stuck draining, find what's blocking it
kubectl describe node <node-name> | grep -A 20 "Non-terminated Pods"

# Force-drain as last resort (will violate PDBs — use with caution)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
```

---

## 9. Quick Reference — Version Commands

```bash
# ── DISCOVERY ────────────────────────────────────────────────────────────────

# What K8s versions does EKS support right now?
aws eks describe-addon-versions \
  --query 'addons[0].addonVersions[0].compatibilities[*].clusterVersion' \
  --output table

# What addon versions are available for K8s 1.32?
aws eks describe-addon-versions \
  --kubernetes-version 1.32 \
  --query 'addons[*].{Addon:addonName,Latest:addonVersions[0].addonVersion,Default:addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion|[0]}' \
  --output table

# What AMI release version to use for node group?
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.32/amazon-linux-2023/x86_64/standard/recommended/release_version \
  --query Parameter.Value --output text

# ARM64 AMI
aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.32/amazon-linux-2023/arm64/standard/recommended/release_version \
  --query Parameter.Value --output text

# ── STATUS ───────────────────────────────────────────────────────────────────

# Cluster version
aws eks describe-cluster --name <cluster> --query cluster.version --output text

# Node versions
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

# Addon versions
aws eks list-addons --cluster-name <cluster> | \
  jq -r '.addons[]' | \
  xargs -I{} aws eks describe-addon --cluster-name <cluster> --addon-name {} \
  --query "addon.{Name:addonName,Version:addonVersion,Status:status}" \
  --output table

# Karpenter node pool nodes
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,kubernetes.io/arch

# ── APPLY ORDER ──────────────────────────────────────────────────────────────

# 1. Control plane
terraform apply -target=aws_eks_cluster.eks

# 2. Managed node group
terraform apply -target=aws_eks_node_group.ondemand-node

# 3. Addons
terraform apply -target=aws_eks_addon.eks-addons

# 4. Karpenter EC2NodeClass (triggers Karpenter node replacement)
terraform apply -target=kubectl_manifest.karpenter_ec2_node_class_default

# 5. Final drift check
terraform apply
```

---

## Upgrade Order Summary

```
┌─────────────────────────────────────────────────────────┐
│                  EKS UPGRADE SEQUENCE                   │
├─────────────────────────────────────────────────────────┤
│  PRE-CHECK                                              │
│    1 All pods healthy                                   │
│    2 PDBs in place for critical workloads               │
│    3 Target addon versions noted                        │
│    4 Karpenter compatibility verified                   │
├─────────────────────────────────────────────────────────┤
│  STEP 1 — Control Plane          (~15 min)              │
│    terraform apply -target=aws_eks_cluster.eks          │
├─────────────────────────────────────────────────────────┤
│  STEP 2 — Managed Node Group     (~5–10 min/node)       │
│    terraform apply -target=aws_eks_node_group.*         │
│    [AWS auto-cordons, drains, replaces each node]       │
├─────────────────────────────────────────────────────────┤
│  STEP 3 — EKS Addons             (~5 min)               │
│    terraform apply -target=aws_eks_addon.*              │
├─────────────────────────────────────────────────────────┤
│  STEP 4 — Karpenter              (~varies)              │
│    4a. Upgrade Karpenter Helm release                   │
│    4b. Bump upgrade-revision annotation in EC2NodeClass │
│    4c. Spot nodes: let expire (7 days) OR force replace │
│    4d. OnDemand nodes: force replace (recommended)      │
├─────────────────────────────────────────────────────────┤
│  POST-VALIDATE                                          │
│    1 All nodes on new version                           │
│    2 All pods Running                                   │
│    3 Addons ACTIVE                                      │
│    4 DNS resolving                                      │
└─────────────────────────────────────────────────────────┘
```