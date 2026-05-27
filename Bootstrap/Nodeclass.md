# EC2NodeClass — Reference Guide

## Overview

The `EC2NodeClass` is the **AWS-specific blueprint** for how Karpenter builds EC2 instances.
It answers the *how* question — every NodePool answers the *what and when*.

```
NodePool      →  "I need a spot arm64 c6g.xlarge"
EC2NodeClass  →  "Here is the AMI, subnet, security group, disk, and boot config to use"
```

All 4 NodePools (`spot-arm64`, `spot-amd64`, `ondemand-arm64`, `ondemand-amd64`) share
this single default EC2NodeClass. You only need multiple NodeClasses if you need
fundamentally different node configurations (e.g. a separate GPU node setup).

---

## Final Configuration

```hcl
resource "kubectl_manifest" "karpenter_ec2_node_class_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      role: "KarpenterNodeRole-${local.cluster_name}"

      amiSelectorTerms:
        - alias: "al2023@latest"

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${local.cluster_name}"

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${local.cluster_name}"

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            iops: 3000
            throughput: 125
            encrypted: true
            deleteOnTermination: true

      userData: |
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          kubelet:
            config:
              imageGCHighThresholdPercent: 75
              imageGCLowThresholdPercent: 70
              evictionHard:
                memory.available: "200Mi"
                nodefs.available: "10%"
              evictionSoft:
                memory.available: "500Mi"
              evictionSoftGracePeriod:
                memory.available: "1m30s"
              maxPods: 110
              systemReserved:
                cpu: "100m"
                memory: "100Mi"
              kubeReserved:
                cpu: "100m"
                memory: "200Mi"

      tags:
        karpenter.sh/discovery: "${local.cluster_name}"
        Environment: "${local.environment}"
        ManagedBy: "karpenter"
        Cluster: "${local.cluster_name}"
  YAML

  depends_on = [helm_release.karpenter]
}
```

---

## Field-by-Field Reference

### `role`

```yaml
role: "KarpenterNodeRole-${local.cluster_name}"
```

The IAM role attached to each EC2 node as an instance profile.
This is **not** the Karpenter controller role — they are two separate roles
with different purposes.

| Role | Who uses it | Purpose |
|---|---|---|
| Karpenter Controller Role | Karpenter pod | Create/terminate EC2 instances |
| KarpenterNodeRole | EC2 node itself | Join the EKS cluster, pull from ECR |

The node role needs exactly these 3 AWS managed policies:

```hcl
# Must be attached before Karpenter starts provisioning nodes
resource "aws_iam_role_policy_attachment" "worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
```

---

### `amiSelectorTerms`

```yaml
amiSelectorTerms:
  - alias: "al2023@latest"
```

Tells Karpenter which operating system image to use when launching nodes.
The `al2023@latest` alias is smart — it **automatically selects the correct
variant** based on the node's architecture:

```
arm64 NodePool  →  Karpenter picks al2023-arm64 AMI automatically
amd64 NodePool  →  Karpenter picks al2023-x86_64 AMI automatically
```

You do not need a separate EC2NodeClass per architecture.

**Available aliases:**

| Alias | Use when |
|---|---|
| `al2023@latest` | Default choice for all new clusters. Modern, secure, fast boot. |
| `al2023@v20240928` | Pin to a specific version for strict compliance or change control. |
| `al2@latest` | Only if you have legacy scripts/tools incompatible with AL2023. Avoid for new setups. |
| `bottlerocket@latest` | Security-focused, immutable OS. Best for regulated environments (PCI, SOC2). Harder to debug. |

**To pin a specific version** (compliance environments):
```yaml
amiSelectorTerms:
  - alias: "al2023@v20240928"   # won't auto-update, fully controlled
```

**To use your own custom baked AMI:**
```yaml
amiSelectorTerms:
  - tags:
      ami-type: "eks-custom-node"
      eks-version: "1.31"
```

---

### `subnetSelectorTerms`

```yaml
subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: "${local.cluster_name}"
```

Karpenter discovers which subnets to launch nodes into via this tag.
It will automatically **spread nodes across all matching subnets** for AZ diversity.

**Critical rule: only tag private subnets.** Nodes must never launch into public subnets.

```
VPC
├── Public Subnet  ap-south-1a   → NO tag  (Karpenter never touches this)
├── Public Subnet  ap-south-1b   → NO tag
├── Private Subnet ap-south-1a   → tag: karpenter.sh/discovery = cluster-name ✅
├── Private Subnet ap-south-1b   → tag: karpenter.sh/discovery = cluster-name ✅
└── Private Subnet ap-south-1c   → tag: karpenter.sh/discovery = cluster-name ✅
```

Tag your private subnets in Terraform:

```hcl
resource "aws_subnet" "private" {
  for_each   = var.private_subnet_cidrs
  vpc_id     = aws_vpc.main.id
  cidr_block = each.value

  tags = {
    "karpenter.sh/discovery"                      = local.cluster_name
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  }
}
```

**Alternative selection methods:**

```yaml
# Multiple tag conditions (AND logic)
subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: "my-cluster"
      tier: "private"

# Specific subnet IDs (useful for isolated NodePools)
subnetSelectorTerms:
  - id: "subnet-0abc123"
  - id: "subnet-0def456"
```

---

### `securityGroupSelectorTerms`

```yaml
securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: "${local.cluster_name}"
```

Same tag-based discovery as subnets. Finds the security group(s) to attach to each node.

Your node security group needs these rules at minimum:

| Direction | From / To | Port | Purpose |
|---|---|---|---|
| Inbound | Cluster SG | All | Node-to-node communication |
| Inbound | Control plane SG | 10250 | Kubelet API (metrics, exec, logs) |
| Outbound | 0.0.0.0/0 | 443 | AWS APIs, ECR, S3 |
| Outbound | 0.0.0.0/0 | All | Inter-pod communication |

**Current Setup**

```hcl
resource "aws_security_group" "node" {
  name   = "${var.cluster_name}-node-sg"
  vpc_id = aws_vpc.main.id

  # ← NO ingress blocks here

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  })
}

```

---

### `blockDeviceMappings`

```yaml
blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 50Gi
      volumeType: gp3
      iops: 3000
      throughput: 125
      encrypted: true
      deleteOnTermination: true
```

Configures the root EBS volume on every node. AL2023's default is 20GB —
too small for production workloads with multiple container images.

**Why gp3 over gp2:**

| | gp2 | gp3 |
|---|---|---|
| IOPS | 3 per GB (burst via credits) | 3,000 baseline always free |
| Throughput | Up to 250 MB/s | 125 MB/s free, up to 1,000 MB/s |
| Cost | $0.10/GB/month | $0.08/GB/month |
| Verdict | Legacy | Always use this |

**How to size the volume:**

```
Per image:        ~2–4 GB
Container logs:   ~1–5 GB
System/kubelet:   ~3–5 GB
Safety buffer:    ~10 GB

Example — 5 images at 3GB average:
  5 × 3 = 15 GB images
  + 5 GB logs
  + 5 GB system
  + 10 GB buffer
  = 35 GB → round up to 50 GB
```

**For I/O-heavy workloads** (Kafka, Elasticsearch):

```yaml
blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 200Gi
      volumeType: gp3
      iops: 6000        # above 3000 has extra cost, worth it for heavy I/O
      throughput: 250   # above 125 has extra cost
      encrypted: true
      deleteOnTermination: true
```

---

### `userData`

```yaml
userData: |
  apiVersion: node.eks.aws/v1alpha1
  kind: NodeConfig
  spec:
    kubelet:
      config:
        imageGCHighThresholdPercent: 75
        imageGCLowThresholdPercent: 70
        evictionHard:
          memory.available: "200Mi"
          nodefs.available: "10%"
        evictionSoft:
          memory.available: "500Mi"
        evictionSoftGracePeriod:
          memory.available: "1m30s"
        maxPods: 110
        systemReserved:
          cpu: "100m"
          memory: "100Mi"
        kubeReserved:
          cpu: "100m"
          memory: "200Mi"
```

Runs on every node at boot time. AL2023 uses `nodeadm` format — this is
**not a bash script**, it is a structured YAML config passed to the node initializer.

#### `imageGCHighThresholdPercent` / `imageGCLowThresholdPercent`

```
Default values: 85 / 80  ← too aggressive for production

With 50GB disk:
  85% threshold = GC starts at 42.5 GB used
  At that point you are already dangerously close to disk pressure

Recommended: 75 / 70
  GC starts at 37.5 GB used — earlier warning, safer headroom
```

Kubelet garbage-collects unused container images (not running containers)
when disk crosses the high threshold, stopping when it reaches the low threshold.

#### `evictionHard` and `evictionSoft`

When these thresholds are crossed, kubelet starts evicting pods.

```
evictionHard  →  Immediate eviction. No warning. Pods killed right away.
evictionSoft  →  Triggers a grace period first. Pods get time to finish.
```

**Eviction order** (kubelet always evicts in this priority):
```
1. BestEffort pods     → no requests/limits set at all
2. Burstable pods      → requests set but lower than limits
3. Guaranteed pods     → requests == limits (safest, evicted last)
```

This is why setting `resources.requests` on every pod matters —
pods without requests are the first to be killed under memory pressure.

```yaml
# Pod that gets killed first under pressure (no requests)
containers:
  - name: app
    image: myapp:latest
    # no resources block = BestEffort = first to die

# Pod that survives longest under pressure (Guaranteed)
containers:
  - name: app
    image: myapp:latest
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "500m"       # limits == requests = Guaranteed QoS
        memory: "512Mi"
```

#### `systemReserved` and `kubeReserved`

```
Without reservations:
  Node has 4 GB RAM
  Kubelet thinks 4 GB is available for pods
  Pods scheduled to use 3.8 GB
  OS + kubelet need 400 MB
  → System starves → node becomes unstable → cascading failures

With reservations:
  systemReserved: 100Mi  (for OS processes: systemd, journald, sshd)
  kubeReserved:   200Mi  (for kubelet + containerd)
  Available for pods: 4 GB - 300 MB = 3.7 GB
  → Stable node even under full pod load
```

Scale these up for larger instances:

| Instance Size | systemReserved | kubeReserved |
|---|---|---|
| Small (2–4 CPU) | `cpu: 100m, memory: 100Mi` | `cpu: 100m, memory: 200Mi` |
| Medium (8–16 CPU) | `cpu: 200m, memory: 300Mi` | `cpu: 200m, memory: 400Mi` |
| Large (32+ CPU) | `cpu: 500m, memory: 500Mi` | `cpu: 500m, memory: 500Mi` |

#### `maxPods`

```
Default: 110

AWS VPC CNI limits pods per node based on ENI count:
  Formula: (ENIs × (IPs per ENI - 1)) + 2

  m5.large:   3 ENIs × 10 IPs = 29 max pods
  m5.xlarge:  4 ENIs × 15 IPs = 58 max pods
  m5.4xlarge: 8 ENIs × 30 IPs = 234 max pods

If you use prefix delegation (recommended for large clusters):
  Each IP slot holds a /28 prefix = 16 IPs
  Effectively multiplies max pods by 16 per ENI slot

Leave at 110 if unsure — kubelet will not exceed the ENI limit anyway.
Only adjust this if you are hitting pod scheduling limits on large nodes.
```

---

### `tags`

```yaml
tags:
  karpenter.sh/discovery: "${local.cluster_name}"
  Environment: "${local.environment}"
  ManagedBy: "karpenter"
  Cluster: "${local.cluster_name}"
```

These tags are applied to the **EC2 instance** in AWS (not the Kubernetes node object).

| Tag | Purpose |
|---|---|
| `karpenter.sh/discovery` | Required — Karpenter uses this to identify nodes it manages |
| `Environment` | Cost Explorer filtering by environment (prod/staging/dev) |
| `ManagedBy` | Identify Karpenter-managed instances vs manually launched |
| `Cluster` | Cost allocation per cluster |

Add any additional cost allocation tags your organization requires:

```yaml
tags:
  karpenter.sh/discovery: "${local.cluster_name}"
  ManagedBy: "karpenter"
  Cluster: "${local.cluster_name}"
  Team: "platform"
  CostCenter: "engineering"
  Project: "my-product"
```

---

## Relationship to NodePools

```
┌──────────────────────────────────────────────────────────────────┐
│  EC2NodeClass "default"                                          │
│  Defines: AMI, subnets, SGs, disk, boot config, tags             │
└───────────────┬──────────────────────────────────────────────────┘
                │ referenced by nodeClassRef in all 4 NodePools
                ▼
   ┌────────────────┬──────────────┬────────────┐
   │                │              │            │
   ▼                ▼              ▼            ▼
spot-arm64    spot-amd64    ondemand-arm64  ondemand-amd64
(weight:100)  (weight:75)   (weight:50)    (weight:10)
```

If you ever need nodes with a different disk size, different AMI, or different
boot config, create a second EC2NodeClass and point a new NodePool at it.
Do not modify the default class — it affects all 4 pools simultaneously.

---

## Common Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Nodes fail to join cluster | Wrong IAM role or missing policy | Verify 3 managed policies attached to node role |
| Nodes launching in wrong subnets | Missing or wrong tag on subnets | Add `karpenter.sh/discovery` tag to private subnets only |
| Pods evicted constantly | `evictionHard` thresholds too high or disk too small | Increase `volumeSize` or lower GC thresholds |
| Nodes running out of pod slots | `maxPods` too low for instance size | Increase `maxPods` or enable prefix delegation |
| Node disk pressure on startup | 20GB default volume too small | Ensure `blockDeviceMappings` is set — AL2023 default is 20GB |