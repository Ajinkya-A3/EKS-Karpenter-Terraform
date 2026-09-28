# EKS Cluster Version Upgrade Runbook

> **Scope:** Covers Terraform-managed EKS clusters with managed node groups, EKS addons, and Karpenter node pools.
> **Rule:** Always upgrade **one minor version at a time** — 1.34 → 1.35 → 1.36. Never skip.
>
> **Version status as of last update (Sep 11, 2026):** Upstream Kubernetes **1.37** GA'd on Aug 26, 2026, but **Amazon EKS does not yet support 1.37**. The newest EKS-supported version at this time is **1.36**. Do not plan a Terraform `cluster_version` bump to `1.37` until AWS publishes an official "Amazon EKS now supports Kubernetes 1.37" announcement and `aws eks describe-addon-versions --kubernetes-version 1.37` returns results in your region. Check before every upgrade cycle — this window closes without much notice.

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
10. [Terraform Gotchas Learned the Hard Way](#10-terraform-gotchas-learned-the-hard-way)

---

## 1. Pre-Upgrade Checklist

Complete every item before touching any Terraform or kubectl command.

### 1.1 Check Current Versions

```bash
# Confirm target version is actually supported by EKS BEFORE editing any Terraform
aws eks describe-addon-versions \
  --query 'addons[0].addonVersions[0].compatibilities[*].clusterVersion' \
  --output table
# If your target version isn't in this list, EKS doesn't support it yet — stop here.

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
aws eks describe-addon-versions \
  --kubernetes-version 1.36 \
  --query 'addons[*].{Addon:addonName, DefaultVersion:addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]}' \
  --output table

# For a specific addon
aws eks describe-addon-versions \
  --kubernetes-version 1.36 \
  --addon-name coredns \
  --query 'addons[0].addonVersions[*].addonVersion' \
  --output table

# METHOD 2 — eksctl (human-friendly output)
eksctl utils describe-addon-versions \
  --kubernetes-version 1.36 \
  --name coredns

eksctl utils describe-addon-versions \
  --kubernetes-version 1.36
```

### 1.2a Find Bridge (Overlapping) Addon Versions

For each addon, this script finds the newest version supported on **both** the old and the new Kubernetes version. That version is the "bridge" version, and it is safe to run across the control-plane/node version skew.

```bash
#!/usr/bin/env bash

OLD_K8S="1.35"
NEW_K8S="1.36"

get_versions() {
  aws eks describe-addon-versions \
    --addon-name "$1" \
    --kubernetes-version "$2" \
    --query 'addons[0].addonVersions[].addonVersion' \
    --output text 2>/dev/null | tr '\t' '\n' | tr -d '\r' | sort -V
}

for addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver metrics-server; do

  old_versions=$(get_versions "$addon" "$OLD_K8S")
  new_versions=$(get_versions "$addon" "$NEW_K8S")

  echo "===== $addon ====="

  if [ -z "$old_versions" ] || [ -z "$new_versions" ]; then
    echo "WARNING: no versions returned for $OLD_K8S or $NEW_K8S - check addon name / region"
    echo
    continue
  fi

  old_latest=$(echo "$old_versions" | tail -1)
  new_latest=$(echo "$new_versions" | tail -1)

  # Intersection: lines from new_versions that exactly match a line in old_versions
  common_version=$(grep -Fxf <(echo "$old_versions") <(echo "$new_versions") | sort -V | tail -1)

  echo "$OLD_K8S latest : $old_latest"
  echo "$NEW_K8S latest : $new_latest"

  if [ -z "$common_version" ]; then
    echo "No overlapping version found - you may need an intermediate hop or must upgrade nodes first for this addon"
  else
    echo "Bridge version (newest common to both): $common_version"
  fi
  echo

done
```

**Example output (1.35 → 1.36):**

```
===== vpc-cni =====
1.35 latest : v1.23.1-eksbuild.1
1.36 latest : v1.23.1-eksbuild.1
Bridge version (newest common to both): v1.23.1-eksbuild.1

===== coredns =====
1.35 latest : v1.14.6-eksbuild.4
1.36 latest : v1.14.6-eksbuild.4
Bridge version (newest common to both): v1.14.6-eksbuild.4

===== kube-proxy =====
1.35 latest : v1.35.3-eksbuild.29
1.36 latest : v1.36.0-eksbuild.25
Bridge version (newest common to both): v1.35.3-eksbuild.29

===== aws-ebs-csi-driver =====
1.35 latest : v1.66.0-eksbuild.1
1.36 latest : v1.66.0-eksbuild.1
Bridge version (newest common to both): v1.66.0-eksbuild.1

===== metrics-server =====
1.35 latest : v0.9.0-eksbuild.11
1.36 latest : v0.9.0-eksbuild.11
Bridge version (newest common to both): v0.9.0-eksbuild.11
```

**How to read it:**
- When both "latest" lines match, that one version already supports both Kubernetes versions. Use it as the bridge and as the final version.
- When they differ (like `kube-proxy` above), the bridge is the newest version common to both. Use it while nodes are still on the old version. After the node group upgrade, move to the new-version latest (`v1.36.0-eksbuild.25` here).
- If the script prints "No overlapping version found", no single version supports both Kubernetes versions. Upgrade that addon after the nodes, or split the upgrade into smaller hops.

### 1.3 Check Karpenter Compatibility

```bash
helm list -n kube-system | grep karpenter
# Then verify against: https://karpenter.sh/docs/upgrading/compatibility/
```

### 1.4 Verify Workload Health

```bash
kubectl get pods --all-namespaces | grep -v "Running\|Completed"
kubectl get pdb --all-namespaces
kubectl get deployments --all-namespaces | awk '$3 == 1 {print}'
kubectl get nodes | grep -v Ready
```

### 1.5 Backup

```bash
kubectl get all --all-namespaces -o yaml > cluster-backup-$(date +%F).yaml
aws eks update-kubeconfig --name <cluster-name> --region <region>
```

---

## 2. Step 1 — Upgrade Control Plane

### 2.1 Update the Variable

```hcl
# variables.tf — type the version explicitly as a string, never a bare number
variable "cluster_version" {
  type    = string
  default = "1.36"   # was "1.35"
}
```

> ⚠️ Declaring `default = 1.36` without `type = string` lets HCL treat it as a number — a value like `1.30` can silently normalize to `1.3` and break your apply downstream. Always quote it and declare `type = string`.

### 2.2 Plan and Apply — Control Plane Only

```bash
terraform plan -target=aws_eks_cluster.eks
terraform apply -target=aws_eks_cluster.eks
```

> ⏱ **EKS control plane upgrades take 10–20 minutes.** The API server is briefly unavailable (~30 seconds) during the transition. `kubectl` may fail during this window — this is normal.

### 2.3 Verify Control Plane

```bash
aws eks describe-cluster \
  --name <cluster-name> \
  --query "cluster.{Version:version, Status:status}" \
  --output table
# Should show: ACTIVE + new version

kubectl version
```

> ⚠️ Nodes are still on the OLD version at this point — that's fine, EKS tolerates one minor version of skew. **Do not skip to addons — upgrade nodes next.**

---

## 3. Step 2 — Upgrade Managed Node Group

### 3.1 Confirm Node Group Config Has These Fields

This is the single most common gap that causes a false "No changes" on `terraform plan`. If `version` and `force_update_version` are missing from your `aws_eks_node_group` resource, Terraform has nothing tying the node group to `var.cluster_version` — bumping the cluster version alone will NOT touch the node group.

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
terraform plan -target=aws_eks_node_group.ondemand-node
terraform apply -target=aws_eks_node_group.ondemand-node
```

### 3.3 What Happens During Node Group Upgrade

```
1. New node launched with updated AMI (kubelet 1.36)
2. Old node cordoned  → no new pods scheduled on it
3. Old node drained   → pods evicted gracefully (respects PDBs)
4. Old node terminated
5. Repeat for next node (max_unavailable = 1 means one at a time)
```

> You do NOT need to manually cordon or drain nodes. AWS does it.

### 3.4 Monitor the Rolling Update

```bash
watch -n 5 kubectl get nodes
watch -n 5 kubectl get pods --all-namespaces

aws eks describe-nodegroup \
  --cluster-name <cluster-name> \
  --nodegroup-name <nodegroup-name> \
  --query "nodegroup.{Status:status, Version:version, ReleaseVersion:releaseVersion}"
```

> ⏱ **Node group rolling update:** ~5–10 minutes per node depending on workload drain time.

### 3.5 Verify Node Group

```bash
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
```

---

## 4. Step 3 — Upgrade EKS Addons

**Always upgrade addons AFTER the node group.** Some addons (like `aws-ebs-csi-driver`) need nodes running to schedule their pods.

### 4.1 Find the Right Addon Versions for Target K8s Version

```bash
aws eks describe-addon-versions \
  --kubernetes-version 1.36 \
  --query 'addons[*].{
    Name: addonName,
    Default: addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0],
    Latest: addonVersions[0].addonVersion
  }' \
  --output table

aws eks describe-addon-versions \
  --kubernetes-version 1.36 \
  --addon-name kube-proxy \
  --query 'addons[0].addonVersions[*].{Version:addonVersion,Default:compatibilities[0].defaultVersion}' \
  --output table

eksctl utils describe-addon-versions --kubernetes-version 1.36 --name kube-proxy
eksctl utils describe-addon-versions --kubernetes-version 1.36 --name coredns
eksctl utils describe-addon-versions --kubernetes-version 1.36 --name vpc-cni
eksctl utils describe-addon-versions --kubernetes-version 1.36 --name aws-ebs-csi-driver
eksctl utils describe-addon-versions --kubernetes-version 1.36 --name metrics-server
```

### 4.2 Update Addon Versions in Terraform

```hcl
addons = [
  { name = "vpc-cni",             version = "v1.22.4-eksbuild.3"  },
  { name = "coredns",             version = "v1.14.3-eksbuild.14" },
  { name = "kube-proxy",          version = "v1.36.0-eksbuild.17" },
  { name = "aws-ebs-csi-driver",  version = "v1.65.0-eksbuild.2"  },
  { name = "metrics-server",      version = "v0.9.0-eksbuild.10"  },
]
```

> Before adding a new addon like `metrics-server`, check it isn't already running via Helm elsewhere in the cluster (`helm list -n kube-system | grep metrics-server`) to avoid a conflicting duplicate install.

### 4.3 Apply Addon Upgrades

```bash
terraform plan -target=aws_eks_addon.eks-addons
terraform apply -target=aws_eks_addon.eks-addons
```

### 4.4 Verify Addons

```bash
aws eks list-addons --cluster-name <cluster-name> --output table

aws eks describe-addon \
  --cluster-name <cluster-name> \
  --addon-name coredns \
  --query "addon.{Status:status,Version:addonVersion}"

kubectl get pods -n kube-system
```

---

## 5. Step 4 — Upgrade Karpenter Node Pools

### 5.1 Two Very Different Behaviors Depending on Your `EC2NodeClass` AMI Configuration

This is the part most teams get wrong, so read carefully before assuming Karpenter "does nothing" until you tell it to.

**Case A — Pinned AMI ID**

```yaml
amiSelectorTerms:
  - id: ami-0123456789abcdef0
```

Karpenter has no signal that anything changed when the control plane is upgraded. Nodes on this NodeClass will **not** move to the new Kubernetes version until:
- They naturally expire (per `expireAfter`), **or**
- You manually force replacement via an annotation bump (Section 5.4 below)

```
Control Plane      → 1.36  ✅ (Terraform)
Managed Node Group → 1.36  ✅ (Terraform, rolling)
Karpenter nodes    → 1.35  ⚠️  still on old kubelet — YOU must handle
```

**Case B — `@latest` AMI alias (the common case)**

```yaml
amiSelectorTerms:
  - alias: al2023@latest
```

Karpenter continuously resolves `@latest` against the **cluster's current Kubernetes version**, discovered dynamically via the EKS API. The moment the control plane finishes upgrading to 1.36, `@latest` starts resolving to a 1.36-built AMI. Karpenter's drift detection then sees existing nodes are running a now-stale AMI, marks them `drifted`, and **automatically** replaces them — no annotation bump needed:

```
1. Karpenter detects control plane version changed
2. @latest alias now resolves to new AMI
3. Existing nodes marked "drifted" (AMI mismatch)
4. Launches replacement node first (new AMI/kubelet)
5. Waits for replacement to be Ready
6. Cordons + drains old node (respects PDBs)
7. Terminates old node
8. Repeats across all NodePools using this NodeClass
```

This happens on its own timeline (usually within minutes of the control plane going `ACTIVE`) — you'll see it in `kubectl get nodeclaim` and `kubectl get nodes` without having applied anything to the `EC2NodeClass`. **This is expected and safe**, not a bug — treat unplanned drift-triggered rotations right after a control plane upgrade as confirmation the alias worked, and verify workload health same as any other rolling replacement (Section 5.5, Section 6).

### 5.2 Is It Safe to Let Karpenter Nodes Expire Naturally? (Pinned-AMI case only)

| NodePool | expireAfter | Safe to Let Expire? | Reason |
|---|---|---|---|
| spot-arm64 | 168h (7 days) | ✅ Usually fine | Replaced within a week |
| spot-amd64 | 168h (7 days) | ✅ Usually fine | Replaced within a week |
| ondemand-arm64 | 720h (30 days) | ⚠️ Risky | Too long if you upgrade frequently |
| ondemand-amd64 | 720h (30 days) | ⚠️ Risky | Same — critical workloads |

**Key risk:** another K8s upgrade before 30-day nodes expire leaves them two minor versions behind — outside the supported skew window.

### 5.3 Option A — Let Expire Naturally (Spot Pools, Pinned-AMI Case)

No action required. Same replace-then-drain sequence as Section 5.1 Case B, just triggered by `expireAfter` instead of drift.

### 5.4 Option B — Force Replace via EC2NodeClass Annotation (Pinned-AMI Case, Recommended for OnDemand)

```hcl
resource "kubectl_manifest" "karpenter_ec2_node_class_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
      annotations:
        upgrade-revision: "2"        # ← was "1", now bump to "2"
    spec:
      # ... rest of config unchanged ...
  YAML
}
```

```bash
terraform apply -target=kubectl_manifest.karpenter_ec2_node_class_default
```

> If you're on the `@latest` alias, you generally don't need this step — drift detection already handled it per Section 5.1 Case B. Only bump this annotation if you need to force a replacement for a reason unrelated to AMI drift (e.g., a config change to the NodeClass itself).

### 5.5 Monitor Karpenter Node Replacement

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --follow
watch -n 5 kubectl get nodes -L karpenter.sh/nodepool,kubernetes.io/arch
kubectl get nodeclaim

kubectl get nodes -o json | jq '.items[] | select(.metadata.annotations["karpenter.sh/disruption-reason"] != null) | {name: .metadata.name, reason: .metadata.annotations["karpenter.sh/disruption-reason"]}'

watch -n 5 kubectl get pods --all-namespaces --field-selector=status.phase!=Running
```

### 5.6 Upgrade Karpenter Itself (Helm)

```bash
helm list -n kube-system | grep karpenter
# Check compatibility: https://karpenter.sh/docs/upgrading/compatibility/

helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.3.3 \           # ← version compatible with your new K8s version
  --namespace kube-system \
  --reuse-values
```

---

## 6. Step 5 — Post-Upgrade Validation

```bash
kubectl get nodes -o wide
kubectl get pods --all-namespaces | grep -v "Running\|Completed\|Succeeded"
kubectl version
aws eks list-addons --cluster-name <cluster-name> --output table

kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -it \
  -- nslookup kubernetes.default

kubectl get storageclass
kubectl get pv

kubectl get nodes -L karpenter.sh/nodepool \
  -o custom-columns='NAME:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion,POOL:.metadata.labels.karpenter\.sh/nodepool'

kubectl get pdb --all-namespaces
```

---

## 7. Workload Interruption Prevention

### 7.1 PodDisruptionBudgets — Most Important

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
  namespace: my-app
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

```bash
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

```bash
kubectl get deployments --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,REPLICAS:.spec.replicas' | \
  awk '$3 == 1 && $1 != "kube-system"'
```

Scale to at least 2 replicas before upgrading any production workload's node.

### 7.3 Pod Anti-Affinity

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

```yaml
spec:
  terminationGracePeriodSeconds: 60
  containers:
    - name: my-app
      lifecycle:
        preStop:
          exec:
            command: ["/bin/sh", "-c", "sleep 5"]
```

### 7.5 Resource Requests and Limits

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
| Karpenter nodes misbehaving (pinned AMI) | Revert `upgrade-revision` annotation; nodes stop being replaced |
| Karpenter nodes misbehaving (`@latest` alias) | Drift is tied to control plane version, not reversible by annotation — pin the AMI explicitly if you need to halt replacement |

```bash
kubectl describe node <node-name> | grep -A 20 "Non-terminated Pods"

# Force-drain as last resort (will violate PDBs — use with caution)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force
```

---

## 9. Quick Reference — Version Commands

```bash
# ── DISCOVERY ────────────────────────────────────────────────────────────────

aws eks describe-addon-versions \
  --query 'addons[0].addonVersions[0].compatibilities[*].clusterVersion' \
  --output table

aws eks describe-addon-versions \
  --kubernetes-version 1.36 \
  --query 'addons[*].{Addon:addonName,Latest:addonVersions[0].addonVersion,Default:addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion|[0]}' \
  --output table

aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/recommended/release_version \
  --query Parameter.Value --output text

aws ssm get-parameter \
  --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/arm64/standard/recommended/release_version \
  --query Parameter.Value --output text

# Bridge (overlapping) addon versions — see full script in Section 1.2a

# ── STATUS ───────────────────────────────────────────────────────────────────

aws eks describe-cluster --name <cluster> --query cluster.version --output text

kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

aws eks list-addons --cluster-name <cluster> | \
  jq -r '.addons[]' | \
  xargs -I{} aws eks describe-addon --cluster-name <cluster> --addon-name {} \
  --query "addon.{Name:addonName,Version:addonVersion,Status:status}" \
  --output table

kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,kubernetes.io/arch
kubectl get nodeclaim

# ── APPLY ORDER ──────────────────────────────────────────────────────────────

terraform apply -target=aws_eks_cluster.eks
terraform apply -target=aws_eks_node_group.ondemand-node
terraform apply -target=aws_eks_addon.eks-addons
terraform apply -target=kubectl_manifest.karpenter_ec2_node_class_default   # only if pinned-AMI
terraform apply   # final drift check across everything
```

---

## 10. Terraform Gotchas Learned the Hard Way

These are real failure modes worth checking before you assume Terraform is "stuck":

1. **`terraform plan -target=aws_eks_cluster.eks` shows "No changes" even after editing `cluster_version`.**
   Check for an override winning over your edit: `terraform.tfvars`, `*.auto.tfvars`, a `TF_VAR_cluster_version` env var, or `-var-file` in your usual apply command. Precedence is `-var`/`-var-file` > `*.auto.tfvars` > `terraform.tfvars` > variable `default`.

2. **`terraform state show aws_eks_cluster.eks` errors with "No instance found."**
   You're in the wrong Terraform root/directory. Run `find . -name "*.tf" | xargs grep -l "aws_eks_cluster"` from the repo root to locate the directory actually wired to your live cluster's state, and `cd` there before continuing.

3. **Node group plan shows "No changes" even though the control plane already moved versions.**
   Your `aws_eks_node_group` resource is missing `version = var.cluster_version` and `force_update_version = true`. Without these, nothing ties the node group to the cluster version variable — add them (Section 3.1) and replan.

4. **Numeric `cluster_version` default silently truncates.**
   `default = 1.30` can become `1.3` under HCL's number type. Always declare `type = string` and quote the value.

5. **Karpenter nodes rotate even though you never touched the `EC2NodeClass`.**
   Expected if you're using an `@latest` AMI alias — see Section 5.1 Case B. Not a bug.
