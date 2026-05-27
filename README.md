# EKS Modules — Terraform Infrastructure README

A two-phase Terraform project that provisions a production-grade Amazon EKS cluster with private node networking, VPC endpoints for NAT cost minimisation, Karpenter autoscaling, and the AWS Load Balancer Controller. The project is split into two root modules — **Infra** and **Bootstrap** — each with its own remote state, applied independently and in order.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Phase 1 — Infra Module](#phase-1--infra-module)
   - [VPC & Networking](#vpc--networking)
   - [Private Subnets & NAT Gateway](#private-subnets--nat-gateway)
   - [VPC Endpoints](#vpc-endpoints)
   - [EKS Cluster](#eks-cluster)
   - [Managed Node Group](#managed-node-group)
   - [EKS Add-ons](#eks-add-ons)
   - [IAM Roles](#iam-roles)
   - [Karpenter IAM & SQS Interruption Queue](#karpenter-iam--sqs-interruption-queue)
   - [ALB Controller IAM](#alb-controller-iam)
   - [Remote State Outputs](#remote-state-outputs)
4. [Phase 2 — Bootstrap Module](#phase-2--bootstrap-module)
   - [Remote State Data Source](#remote-state-data-source)
   - [AWS Load Balancer Controller](#aws-load-balancer-controller)
   - [Karpenter Installation](#karpenter-installation)
   - [Karpenter NodePool & EC2NodeClass](#karpenter-nodepool--ec2nodeclass)
5. [State Backend](#state-backend)
6. [Provider Configuration](#provider-configuration)
7. [Variables Reference](#variables-reference)
8. [Outputs Reference](#outputs-reference)
9. [Deployment Order & Commands](#deployment-order--commands)
10. [Design Decisions & Notes](#design-decisions--notes)
11. [Prerequisites](#prerequisites)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Phase 1: Infra                                                  │
│                                                                  │
│  VPC (10.0.0.0/16)   enable_dns_support = true                   │
│  │                                                               │
│  ├── Public Subnet AZ-a  (10.0.0.0/24)  ──► IGW                  │
│  ├── Public Subnet AZ-b  (10.0.1.0/24)  ──► IGW                  │
│  │       └── NAT Gateway (single, AZ-a)                          │
│  │                                                               │
│  ├── Private Subnet AZ-a (10.0.10.0/24) ──► NAT Gateway          │
│  └── Private Subnet AZ-b (10.0.11.0/24) ──► NAT Gateway          │
│          │   (karpenter.sh/discovery tag)                        │
│          │   (kubernetes.io/role/internal-elb tag)               │
│          │                                                       │
│          └── All nodes & Karpenter-provisioned instances         │
│                                                                  │
│  VPC Endpoints (bypass NAT entirely)                             │
│  ├── Gateway: S3, DynamoDB          (free)                       │
│  └── Interface: ECR API, ECR DKR,                                │
│       EC2, STS, SQS, EKS,                                        │
│       SSM, SSMMessages, EC2Messages  (~$7-8/mo each)             │
│                                                                  │
│  EKS Cluster (API auth mode)                                     │
│  ├── Control plane ENIs in both public + private subnets         │
│  ├── Public endpoint  (kubectl from laptop)                      │
│  ├── Private endpoint (nodes reach API internally)               │
│  ├── OIDC Provider                                               │
│  ├── Managed Node Group (ON_DEMAND, private subnets)             │
│  └── Add-ons: vpc-cni, coredns, kube-proxy, ebs-csi              │
│                                                                  │
│  IAM Roles                                                       │
│  ├── Cluster Role                                                │
│  ├── Node Role                                                   │
│  ├── EBS CSI Controller Role (IRSA)                              │
│  ├── ALB Controller Role (IRSA)                                  │
│  ├── Karpenter Node Role + EKS Access Entry                      │
│  └── Karpenter Controller Role (IRSA)                            │
│                                                                  │
│  SQS + EventBridge (Karpenter Interruption Handlinig)            │
│  ├── Spot Interruption Warning                                   │
│  ├── Instance Rebalance Recommendation                           │
│  ├── Instance State Change                                       │
│  └── AWS Health Scheduled Change                                 │
└──────────────────────────────────────────────────────────────────┘
                          │
                  S3 Remote State
                          │
┌──────────────────────────────────────────────────────────────────┐
│  Phase 2: Bootstrap                                              │
│                                                                  │
│  Helm: AWS Load Balancer Controller (kube-system)                │
│  Helm: Karpenter CRDs                                            │
│  Helm: Karpenter Controller (karpenter namespace)                │
│         └── Pinned to managed node group via node affinity       │
│                                                                  │
│  kubectl_manifest:                                               │
│  ├── NodePool (default) — spot + on-demand, c/m/r families       │
│  └── EC2NodeClass (default) — AL2023, private subnet discovery   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
EKS-Modules/
├── Infra/                          # Phase 1 — AWS infrastructure
│   ├── vpc.tf                      # VPC, public/private subnets, IGW, NAT, route tables, SGs
│   ├── vpc_endpoints.tf            # All VPC endpoints (gateway + interface) for NAT cost reduction
│   ├── eks.tf                      # EKS cluster, OIDC, launch template, node group, add-ons, EBS CSI role
│   ├── iam.tf                      # Cluster role + Node role
│   ├── karpenter_iam.tf            # Karpenter node role, controller role (IRSA), EKS access entry
│   ├── karpenter_sqs.tf            # SQS interruption queue + 4 EventBridge rules
│   ├── alb_iam.tf                  # ALB controller IAM policy + role (IRSA)
│   ├── outputs.tf                  # All outputs consumed by Bootstrap via remote state
│   ├── variables.tf                # Input variables with sensible defaults
│   ├── provider.tf                 # AWS, Kubernetes, Helm, kubectl providers
│   ├── versions.tf                 # Terraform + provider version pins
│   ├── backend.tf                  # S3 backend (key: Infra/terraform.tfstate)
│   └── policies/
│       ├── alb_iam_policy.json     # Full ALB controller IAM policy document
│       └── karpenter-controller-policy.json  # Karpenter controller policy (templatefile)
│
└── Bootstrap/                      # Phase 2 — Kubernetes-level bootstrapping
    ├── alb.tf                      # Service account + Helm release for ALB controller
    ├── karpenter_install.tf        # Namespace + Helm releases for Karpenter CRDs and controller
    ├── karpenter_nodepool.tf       # NodePool and EC2NodeClass kubectl_manifests
    ├── data.tf                     # terraform_remote_state from Infra + locals
    ├── output.tf                   # Karpenter Helm release status
    ├── variables.tf                # region, karpenter_version, karpenter_namespace
    ├── provider.tf                 # AWS, Kubernetes, Helm, kubectl (exec-based auth)
    ├── versions.tf                 # Terraform + provider version pins
    └── backend.tf                  # S3 backend (key: Bootstrap/terraform.tfstate)
```

---

## Phase 1 — Infra Module

### VPC & Networking

**File:** `Infra/vpc.tf`

The VPC is created with both `enable_dns_hostnames` and `enable_dns_support` set to `true`. The `enable_dns_support` flag is not optional — it is **required for interface endpoint private DNS resolution**. Without it, service hostnames like `sqs.ap-south-1.amazonaws.com` won't resolve to the endpoint ENI IPs inside the VPC and will fall through to public IPs, sending traffic through NAT and defeating the purpose of the endpoints.

**Public Subnets** are created with `map_public_ip_on_launch = true` and carry two tags:

| Tag | Value | Purpose |
|-----|-------|---------|
| `kubernetes.io/role/elb` | `1` | Marks subnets as eligible for internet-facing ALBs |
| `kubernetes.io/cluster/<name>` | `owned` | EKS subnet ownership marker |

Note that `karpenter.sh/discovery` is intentionally **absent** from public subnets — Karpenter should only ever launch nodes into private subnets.

**Security Groups** define ingress rules as separate `aws_security_group_rule` resources (not inline blocks) with `lifecycle { ignore_changes = [ingress] }`. This prevents Terraform from conflicting with EKS's own dynamic ingress rule management. The following rules are created:

| Rule | From | To | Purpose |
|------|------|----|---------|
| `cluster_to_node` | EKS Cluster SG | Node SG | Control plane → workers, all traffic |
| `node_to_cluster` | Node SG | EKS Cluster SG | Workers → control plane, all traffic |
| `node_to_node` | Node SG (self) | Node SG | Pod-to-pod and node-to-node |
| `cluster_api_access` | `0.0.0.0/0` | EKS Cluster SG (443) | Public kubectl / API access |
| `alb_to_node` | VPC CIDR | Node SG (all TCP) | ALB → NodePort services |

---

### Private Subnets & NAT Gateway

**File:** `Infra/vpc.tf`

Private subnets are created with the same count as public subnets (`var.public_subnet_count`), one per AZ, using a CIDR offset of `+10` to avoid collision:

| Subnet | CIDR | AZ |
|--------|------|----|
| `public-0` | `10.0.0.0/24` | AZ-a |
| `public-1` | `10.0.1.0/24` | AZ-b |
| `private-0` | `10.0.10.0/24` | AZ-a |
| `private-1` | `10.0.11.0/24` | AZ-b |

Private subnets carry three tags:

| Tag | Value | Purpose |
|-----|-------|---------|
| `kubernetes.io/role/internal-elb` | `1` | Internal ALB subnet eligibility |
| `kubernetes.io/cluster/<name>` | `owned` | EKS ownership |
| `karpenter.sh/discovery` | `<cluster-name>` | Karpenter subnet discovery — private subnets only |

**Single NAT Gateway** is placed in `public[0]` (AZ-a). All private subnets across all AZs share one private route table pointing `0.0.0.0/0` to this NAT. The cost trade-off: nodes in AZ-b routing to the internet via NAT in AZ-a incur cross-AZ data transfer charges (~$0.01/GB), but with VPC endpoints in place, the actual volume of NAT traffic is minimal — only truly external destinations (DockerHub, GitHub, `apt` repos) go through NAT.

A single `aws_eip` is allocated with `depends_on = [aws_internet_gateway.igw]` — this dependency is required because EIP allocation can race with IGW attachment.

---

### VPC Endpoints

**File:** `Infra/vpc_endpoints.tf`

All AWS service traffic from nodes bypasses the NAT Gateway entirely via VPC endpoints. Endpoints are split into two types:

#### Gateway Endpoints — Free

No hourly cost, no data processing charge, no security group required. Traffic is routed directly from the route table.

| Endpoint | Service Name | Attached Route Tables | Why |
|----------|-------------|----------------------|-----|
| `s3` | `com.amazonaws.<region>.s3` | private + public | ECR stores every image layer in S3. The single biggest source of NAT data charges on any EKS cluster. |
| `dynamodb` | `com.amazonaws.<region>.dynamodb` | private + public | Free to add; used by some AWS SDK internals. |

Both gateway endpoints are attached to both the private and public route tables so they are reachable from anywhere in the VPC.

#### Interface Endpoints — ~$7–8/month each (ap-south-1)

Endpoint ENIs are placed in **private subnets** with `private_dns_enabled = true`. This makes the standard public AWS service DNS names (e.g. `sqs.ap-south-1.amazonaws.com`) resolve to private IPs inside the VPC — no code or config changes needed anywhere.

All interface endpoints share a single **`vpc_endpoints_sg`** security group that permits inbound TCP 443 from `var.vpc_cidr` only.

| Endpoint | Service | Traffic Intercepted |
|----------|---------|---------------------|
| `ecr_api` | `ecr.api` | Image manifest fetches and ECR auth token requests |
| `ecr_dkr` | `ecr.dkr` | Docker registry layer pulls. Works in tandem with the S3 gateway endpoint — manifest via `ecr.dkr`, layers via S3, both completely bypassing NAT |
| `ec2` | `ec2` | All Karpenter EC2 API calls: `RunInstances`, `CreateFleet`, `DescribeInstances`, `TerminateInstances`, `DescribeSpotPriceHistory`, etc. Very high call frequency |
| `sts` | `sts` | `AssumeRoleWithWebIdentity` for every IRSA pod — Karpenter controller, ALB controller, and EBS CSI driver all call this on startup and on every token refresh |
| `sqs` | `sqs` | Karpenter polls the interruption queue in a continuous loop. Every poll would otherwise cross the NAT |
| `eks` | `eks` | Node bootstrap `DescribeCluster` calls and ongoing kubelet API communication |
| `ssm` | `ssm` | SSM Session Manager — first of the required trio |
| `ssmmessages` | `ssmmessages` | SSM data channel — second of the required trio |
| `ec2messages` | `ec2messages` | SSM command delivery — third of the required trio. All three are required together; removing any one breaks SSM access to nodes |

**Cost break-even:** At ap-south-1 pricing, 9 interface endpoints cost roughly $130–140/month fixed. This breaks even against NAT data charges at approximately 1.5–2 TB/month of AWS API traffic. An active cluster with Karpenter scaling, rolling deployments, and SSM access will typically exceed this.

---

### EKS Cluster

**File:** `Infra/eks.tf`

```hcl
vpc_config {
  subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
  endpoint_public_access  = true
  endpoint_private_access = true
}
```

**Both subnet types are passed** for a specific reason: `subnet_ids` in the cluster resource controls where EKS places **control plane ENIs** — not where nodes run. EKS uses these ENIs to establish network connectivity between the managed control plane (running in AWS's account) and resources inside your VPC.

- Private subnets are needed so control plane ENIs have a direct network path to nodes (which live in private subnets)
- Public subnets are needed to anchor the public API endpoint, which requires a subnet with IGW routing

**Both endpoint access modes are enabled:**
- `endpoint_public_access = true` — allows `kubectl` from your workstation
- `endpoint_private_access = true` — nodes in private subnets reach the API server without leaving the VPC. Without this, API calls from nodes would exit through NAT and re-enter via the public endpoint, adding latency and unnecessary NAT charges

The cluster uses `authentication_mode = API` — the modern access entry model. No `aws-auth` ConfigMap is needed.

---

### Managed Node Group

**File:** `Infra/eks.tf`

```hcl
subnet_ids = aws_subnet.private[*].id   # private subnets only
```

The managed node group launches exclusively into private subnets. Nodes have no public IPs. All outbound traffic (ECR pulls, SSM, AWS API calls) routes through either VPC endpoints or the NAT Gateway for truly external destinations.

The `depends_on` includes `aws_nat_gateway.nat` — this ensures NAT is fully provisioned before nodes attempt to pull container images. Without this, nodes can boot before NAT is ready, fail their initial image pulls, and enter a crash loop.

Key launch template settings:
- IMDSv2 enforced (`http_tokens = required`) — prevents SSRF attacks against the metadata service
- 20 GB encrypted `gp3` root volume
- Detailed tagging on instance, volume, and ENI resources

---

### EKS Add-ons

**File:** `Infra/eks.tf`

| Add-on | Default Version | Notes |
|--------|----------------|-------|
| `vpc-cni` | v1.21.1-eksbuild.1 | AWS pod networking |
| `coredns` | v1.13.2-eksbuild.3 | Cluster DNS |
| `kube-proxy` | v1.35.0-eksbuild.2 | Network rules on each node |
| `aws-ebs-csi-driver` | v1.57.1-eksbuild.1 | PersistentVolume support; receives its own IRSA role (`ebs-csi-controller-role`) with `AmazonEBSCSIDriverPolicy` |

Add-ons are driven by a `var.addons` list — extend it to add more without changing the resource block.

---

### IAM Roles

**File:** `Infra/iam.tf`

**EKS Cluster Role** (`<cluster-name>-cluster-role`): Trusted by `eks.amazonaws.com`. Policy: `AmazonEKSClusterPolicy`.

**Node Role** (`<cluster-name>-node-role`): Trusted by `ec2.amazonaws.com`. Policies applied via `for_each`:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonEKS_CNI_Policy`
- `AmazonSSMManagedInstanceCore` — enables SSM Session Manager on all managed nodes

---

### Karpenter IAM & SQS Interruption Queue

**Files:** `Infra/karpenter_iam.tf`, `Infra/karpenter_sqs.tf`
Karpenter requires two separate IAM roles — one for the nodes it launches, one for its own controller pod.

**Karpenter Node Role** (`KarpenterNodeRole-<cluster-name>`): Trusted by `ec2.amazonaws.com`. Policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryPullOnly`
- `AmazonSSMManagedInstanceCore`

Since the cluster uses `authentication_mode = API`, node access is granted via an `aws_eks_access_entry` resource of type `EC2_LINUX` — no aws-auth ConfigMap required.

**Karpenter Controller Role** (`KarpenterControllerRole-<cluster-name>`): IRSA role. The trust policy is scoped via `StringEquals` conditions on both `:aud` (`sts.amazonaws.com`) and `:sub` (`system:serviceaccount:karpenter:karpenter`). The inline policy is rendered from `policies/karpenter-controller-policy.json` using `templatefile()` with substitutions for cluster name, region, node role ARN, cluster ARN, and SQS queue ARN.

| Template Variable | Value |
|------------------|-------|
| `${cluster_name}` | Cluster name |
| `${region}` | AWS region |
| `${karpenter_node_role_arn}` | Node role ARN (for `iam:PassRole`) |
| `${eks_cluster_arn}` | Cluster ARN (for `eks:DescribeCluster`) |
| `${sqs_queue_arn}` | SQS queue ARN |

The policy grants Karpenter the ability to launch instances, create/delete launch templates, manage instance profiles (scoped to Karpenter-owned profiles via tag conditions), terminate instances tagged with `karpenter.sh/nodepool`, and interact with the SQS interruption queue.

**SQS Interruption Queue** (`<cluster-name>-karpenter-spot-events`): Receives events from four EventBridge rules so Karpenter can gracefully cordon and drain nodes before AWS reclaims them:

| Rule | Event | Purpose |
|------|-------|---------|
| `spot_interruption` | EC2 Spot Interruption Warning | 2-minute warning before Spot reclaim |
| `rebalance_recommendation` | EC2 Instance Rebalance Recommendation | Early replacement of at-risk Spot nodes |
| `instance_state_change` | EC2 State-change Notification | Catch unexpected terminations |
| `scheduled_change` | AWS Health Event | AWS maintenance window notifications |

The SQS queue policy allows `events.amazonaws.com` to `sqs:SendMessage` only from the ARNs of these four rules (using `aws:SourceArn` condition). SSE is enabled with SQS-managed keys. Message retention is 14 days; visibility timeout is 5 minutes.

---

### ALB Controller IAM

**File:** `Infra/alb_iam.tf`

The ALB Controller requires a comprehensive IAM policy (loaded from `policies/alb_iam_policy.json`) covering EC2 describe actions, ELBv2 CRUD operations, security group management, WAF/Shield integration, ACM certificate lookups, and Cognito. The policy file is the official AWS-provided policy for the controller.

An IRSA role (`alb-controller-role`) is created with a trust policy scoped to `system:serviceaccount:kube-system:aws-load-balancer-controller`.

---

### Remote State Outputs

**File:** `Infra/outputs.tf`

Everything the Bootstrap module needs is exported as outputs and stored in the Infra S3 state key. Key outputs include:

- `cluster_name`, `cluster_endpoint`, `cluster_ca` (sensitive)
- `vpc_id`, `public_subnets`
- `node_group_name` (used to pin Karpenter pods via node affinity)
- `alb_controller_role_arn`
- `karpenter_controller_role_arn`, `karpenter_node_role_arn`
- `karpenter_sqs_queue_name`, `karpenter_sqs_queue_url`, `karpenter_sqs_queue_arn`
- `oidc_provider_arn`, `cluster_oidc_issuer_url`

---

## Phase 2 — Bootstrap Module

### Remote State Data Source

**File:** `Bootstrap/data.tf`

No values are hardcoded in Bootstrap. Everything is pulled from the Infra remote state:

```hcl
data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "terraform-s3-state-007"
    key    = "Infra/terraform.tfstate"
    region = "ap-south-1"
  }
}
```

All outputs are aliased to locals (`local.cluster_name`, `local.vpc_id`, `local.karpenter_queue_name`, etc.) for clean usage throughout the module.

---

### AWS Load Balancer Controller

**File:** `Bootstrap/alb.tf`

Two resources are created:

1. **`kubernetes_service_account_v1.alb`** in `kube-system` — annotated with `eks.amazonaws.com/role-arn` pointing to the ALB controller IRSA role. Creating the service account before the Helm release and disabling Helm's own SA creation prevents a double-create conflict.

2. **`helm_release.alb`** from `https://aws.github.io/eks-charts` — key chart values set:
   - `clusterName` — EKS cluster name
   - `serviceAccount.create = false` — use the pre-created SA
   - `serviceAccount.name` — name of the SA above
   - `vpcId` — required for IP target type ALBs
   - `region` — AWS region

   `cleanup_on_fail = true` and `wait = true` with a 600-second timeout ensure idempotent installs.

---

### Karpenter Installation

**File:** `Bootstrap/karpenter_install.tf`

Three resources, applied in this order:

1. **`kubernetes_namespace_v1.karpenter`** — creates the `karpenter` namespace (controlled by `var.karpenter_namespace`, default `karpenter`).

2. **`helm_release.karpenter_crds`** — installs the `karpenter-crd` chart from `oci://public.ecr.aws/karpenter`. CRDs are installed as a **separate Helm release** from the controller — this is intentional. If both are in the same release, a Helm upgrade that changes a CRD can fail because Helm tries to replace immutable CRD fields. Separating them gives lifecycle independence.

3. **`helm_release.karpenter`** — installs the `karpenter` chart with:
   - `settings.clusterName` — cluster name
   - `settings.interruptionQueue` — SQS queue name for interruption handling
   - `serviceAccount.annotations` — IRSA annotation with the controller role ARN
   - CPU/memory requests and limits set to `1 CPU / 1Gi` each
   - **Node Affinity** — pins Karpenter pods to the existing managed node group using the `eks.amazonaws.com/nodegroup` label. This prevents a chicken-and-egg problem where Karpenter would need to schedule itself but no Karpenter nodes exist yet.

   The `depends_on` chain: `karpenter_crds` → `alb` ensures ALB is ready before CRDs, and CRDs before the controller.

---

### Karpenter NodePool & EC2NodeClass

**File:** `Bootstrap/karpenter_nodepool.tf`

Two `kubectl_manifest` resources apply Karpenter CRD instances as inline YAML:

**`NodePool` (default):**

| Field | Value | Meaning |
|-------|-------|---------|
| `kubernetes.io/arch` | `amd64` | x86 nodes only |
| `kubernetes.io/os` | `linux` | Linux only |
| `karpenter.sh/capacity-type` | `spot, on-demand` | Both capacity types allowed |
| `karpenter.k8s.aws/instance-category` | `c, m, r` | Compute, Memory, Memory-optimized families |
| `karpenter.k8s.aws/instance-generation` | `> 3` | Only 4th gen and newer |
| `expireAfter` | `720h` (30 days) | Nodes are replaced after 30 days (drift/security patching) |
| `limits.cpu` | `1000` | Hard cap: cluster will not scale beyond 1000 vCPUs via Karpenter |
| `consolidationPolicy` | `WhenEmptyOrUnderutilized` | Aggressive cost optimization |
| `consolidateAfter` | `1m` | Consolidation check interval |

**`EC2NodeClass` (default):**

| Field | Value | Meaning |
|-------|-------|---------|
| `role` | `KarpenterNodeRole-<cluster-name>` | IAM role for launched instances |
| `amiSelectorTerms` | `al2023@latest` | Always use latest Amazon Linux 2023 AMI |
| `subnetSelectorTerms` | tag: `karpenter.sh/discovery: <cluster-name>` | Discovers **private subnets only** — the tag exists only on private subnets |
| `securityGroupSelectorTerms` | tag: `karpenter.sh/discovery: <cluster-name>` | Discovers node SG by tag |

Because `karpenter.sh/discovery` was placed **only on private subnets** in `vpc.tf`, Karpenter-provisioned nodes automatically land in private subnets with no additional configuration in the EC2NodeClass.

---

## State Backend

Both modules use S3 as the Terraform backend with **native S3 locking** (`use_lockfile = true`, available in Terraform ≥ 1.10):

| Module | S3 Key |
|--------|--------|
| Infra | `Infra/terraform.tfstate` |
| Bootstrap | `Bootstrap/terraform.tfstate` |

Both share the same bucket (`terraform-s3-state-007`) in `ap-south-1` with encryption enabled. No DynamoDB lock table is required.

---

## Provider Configuration

| Provider | Source | Version |
|----------|--------|---------|
| `aws` | `hashicorp/aws` | 6.38.0 |
| `kubernetes` | `hashicorp/kubernetes` | 3.0.1 |
| `helm` | `hashicorp/helm` | 3.1.1 |
| `kubectl` | `gavinbunney/kubectl` | 1.19.0 |

**Infra** authenticates Kubernetes/Helm/kubectl providers via a static token from `data.aws_eks_cluster_auth`. This works during initial provisioning because Infra creates the cluster and reads it back in the same apply.

**Bootstrap** uses the `exec` approach (`aws eks get-token`) — fetches a fresh short-lived token at plan/apply time. This is the recommended pattern for CI/CD pipelines.

---

## Variables Reference

### Infra Variables (`Infra/variables.tf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `ap-south-1` | AWS region |
| `cluster_name` | `demo` | EKS cluster name; used as prefix for all resources |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `cluster_version` | `1.35` | EKS Kubernetes version |
| `instance_type` | `t3.medium` | Managed node group instance type |
| `desired_size` | `2` | Node group desired count |
| `max_size` | `3` | Node group max count |
| `min_size` | `1` | Node group min count |
| `public_subnet_count` | `2` | Number of AZs — creates this many public AND private subnets |
| `addons` | (list) | EKS managed add-ons; extend by adding entries to the list |
| `tags` | `{Environment=dev, Terraform=true}` | Default tags merged onto all resources |
| `karpenter_namespace` | `karpenter` | Kubernetes namespace; must match the IRSA trust condition |

### Bootstrap Variables (`Bootstrap/variables.tf`)

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `ap-south-1` | AWS region |
| `karpenter_version` | `1.11.0` | Helm chart version for both `karpenter` and `karpenter-crd` charts |
| `karpenter_namespace` | `karpenter` | Kubernetes namespace for Karpenter |

---

## Outputs Reference

### Infra Outputs

| Output | Sensitive | Description |
|--------|-----------|-------------|
| `cluster_name` | No | EKS cluster name |
| `cluster_endpoint` | No | EKS API server endpoint |
| `cluster_version` | No | Kubernetes version |
| `cluster_oidc_issuer_url` | No | OIDC issuer URL |
| `cluster_ca` | **Yes** | Base64 cluster CA certificate |
| `kubectl_config` | No | Map of `cluster_name` and `region` for kubeconfig |
| `node_group_name` | No | Managed node group name |
| `node_group_status` | No | Node group status |
| `vpc_id` | No | VPC ID |
| `public_subnets` | No | List of public subnet IDs |
| `internet_gateway_id` | No | IGW ID |
| `eks_cluster_sg` | No | EKS cluster security group ID |
| `node_sg` | No | Node security group ID |
| `eks_cluster_role_arn` | No | EKS cluster IAM role ARN |
| `node_role_arn` | No | Node IAM role ARN |
| `oidc_provider_arn` | No | OIDC provider ARN |
| `alb_controller_role_arn` | No | ALB controller IRSA role ARN |
| `karpenter_node_role_arn` | No | Karpenter node IAM role ARN |
| `karpenter_controller_role_arn` | No | Karpenter controller IRSA role ARN |
| `karpenter_sqs_queue_url` | No | Interruption queue URL |
| `karpenter_sqs_queue_arn` | No | Interruption queue ARN |
| `karpenter_sqs_queue_name` | No | Interruption queue name |

### Bootstrap Outputs

| Output | Description |
|--------|-------------|
| `karpenter_status` | Helm release status of the Karpenter chart |

---

## Deployment Order & Commands

### Prerequisites

```bash
# Confirm AWS credentials and identity
aws sts get-caller-identity

# Confirm Terraform version (>= 1.11.0 required)
terraform version

# Ensure the S3 state bucket exists with versioning enabled
aws s3api get-bucket-versioning --bucket terraform-s3-state-007
```

### Step 1 — Apply Infra

```bash
cd Infra/

terraform init
terraform plan -out=infra.tfplan
terraform apply infra.tfplan
```

Approximate apply time: 20–25 minutes. EKS cluster creation (~15 min) dominates; VPC endpoint provisioning adds a few minutes on top.

### Step 2 — Update kubeconfig

```bash
aws eks update-kubeconfig \
  --name demo \
  --region ap-south-1

kubectl get nodes
```

### Step 3 — Apply Bootstrap

```bash
cd ../Bootstrap/

terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Approximate apply time: 5–8 minutes (Helm releases with `wait = true`).

### Step 4 — Verify

```bash
# ALB controller running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Karpenter running and pinned to managed node group
kubectl get pods -n karpenter -o wide

# NodePool and EC2NodeClass applied
kubectl get nodepools
kubectl get ec2nodeclasses

# Confirm VPC endpoints are active (from AWS side)
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=<your-vpc-id>" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' \
  --output table
```

### Teardown

```bash
# Destroy in reverse order — Bootstrap first, then Infra
cd Bootstrap/
terraform destroy

cd ../Infra/
terraform destroy
```

> **Note:** Destroy can fail if Karpenter-provisioned nodes or ALB-managed load balancers still exist. Scale down workloads and manually delete ALBs/target groups before running `terraform destroy` on Infra.

---

## Design Decisions & Notes

**Two-module split:** Infra and Bootstrap are separate because Bootstrap requires a live EKS API server. A single apply fails because the Kubernetes/Helm providers cannot initialise against a cluster that doesn't exist yet.

**Private nodes, public ALB:** Nodes sit in private subnets with no public IPs. The ALB Controller provisions internet-facing ALBs in public subnets using the `kubernetes.io/role/elb: 1` tag. Traffic path: internet → ALB (public subnet) → NodePort on private node. No node is ever directly internet-reachable.

**`karpenter.sh/discovery` on private subnets only:** By placing this tag exclusively on private subnets, Karpenter's EC2NodeClass automatically discovers only private subnets for node placement — no explicit subnet ID list required, and no risk of a Karpenter node accidentally landing in a public subnet.

**Both `endpoint_public_access` and `endpoint_private_access` enabled:** Public access keeps `kubectl` working from developer machines. Private access ensures nodes reach the API server over the VPC's internal network rather than through NAT, reducing both latency and NAT data charges.

**Single NAT Gateway:** One NAT in AZ-a serves all private subnets. With VPC endpoints absorbing ECR, S3, STS, EC2, SQS, SSM, and EKS traffic, the actual data volume hitting NAT is very low — only external destinations like DockerHub, GitHub, and package repos. The cross-AZ data charge for AZ-b nodes routing through AZ-a NAT is negligible at this traffic level.

**Gateway endpoints on both route tables:** S3 and DynamoDB gateway endpoints are added to both the private and public route tables. This ensures the free routing applies to all traffic in the VPC regardless of subnet tier, not just private subnet traffic.

**Karpenter CRDs as a separate Helm release:** Installing `karpenter-crd` separately from `karpenter` allows CRDs to be upgraded independently. Helm cannot safely replace CRDs that are part of the same release as the controller — separating them eliminates this lifecycle constraint.

**Karpenter pinned to managed node group:** The node affinity in the Karpenter Helm release ensures Karpenter's own pods run on the stable ON_DEMAND managed node group. This prevents the bootstrap deadlock where Karpenter would need to schedule itself but no Karpenter-managed nodes exist yet.

**`expireAfter: 720h` on NodePool:** Nodes are voluntarily replaced every 30 days. Since the EC2NodeClass uses `al2023@latest`, each replacement picks up the latest patched AMI — automated OS patch compliance without any manual intervention.

**`depends_on = [aws_nat_gateway.nat]` on node group:** Ensures NAT is fully available before the first node attempts to pull a container image. Without this explicit dependency, Terraform may create the node group before NAT is ready, causing image pull failures and node registration failures during the initial apply.