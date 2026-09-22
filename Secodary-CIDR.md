# Secondary CIDR — Dealing with IP Exhaustion

This document describes the **VPC CNI custom networking** setup used to give
pods their own IP range, separate from the primary VPC CIDR, to solve IP
exhaustion in the node subnets. It's fully toggle-controlled via
`enable_pod_custom_networking` — when off, nothing described here is created
and the cluster behaves exactly as it did before.

---

## Why this exists

Pods on EKS normally get IP addresses from the **same subnet as the node's
primary ENI** (the VPC CNI attaches secondary ENIs in that same subnet and
hands their IPs to pods). On a `/24` per-AZ subnet, that space gets consumed
fast once you're running dozens of pods per node across several nodes — you
run out of pod IPs long before you run out of compute.

**Custom networking** fixes this by:
1. Associating a **second, much larger CIDR** with the VPC (in addition to
   your primary `10.0.0.0/16`).
2. Carving **dedicated pod subnets** out of that secondary CIDR, one per AZ.
3. Telling the VPC CNI, via an `ENIConfig` per AZ, to hand out pod IPs from
   those subnets instead of the node's own subnet.

The node's primary ENI still lives in your existing private subnet and is
still used for node-level traffic (kubelet, health checks, etc.) — only pod
IPs move to the secondary range.

---

## How it works, end to end

1. A secondary CIDR (`100.64.0.0/16` by default — the CGNAT range, chosen
   because it can never collide with RFC1918 space used by peered VPCs or
   on-prem networks) is associated with the VPC.
2. One pod subnet is carved out of that CIDR per AZ, routed through the
   **same NAT Gateway** your private subnets already use.
3. The `vpc-cni` addon is reconfigured with:
   - `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true` — the master switch; tells the
     CNI to stop assigning pod IPs from the node's own subnet and instead
     look up an `ENIConfig`.
   - `ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone` — tells the CNI to
     pick the `ENIConfig` whose name matches the node's **AZ label**. This is
     a standard Kubernetes label every node already has (including
     Karpenter-provisioned ones) — no manual labeling needed.
4. One `ENIConfig` custom resource is created per AZ, each pointing at that
   AZ's pod subnet and the shared node security group.
5. Because one ENI slot on every node is now dedicated to the node itself
   (and its IPs aren't available to pods), **Karpenter's controller** is told
   this via `RESERVED_ENIS=1`, so its own max-pods-per-node math stays
   accurate.

### What does *not* need to change

- **Karpenter NodePools / EC2NodeClass** — untouched. Karpenter nodes launch
  into the same private subnets as before (selected via the
  `karpenter.sh/discovery` tag) and automatically pick up the right
  `ENIConfig` because `topology.kubernetes.io/zone` is set on every node by
  default.
- **Node security group rules** that reference the SG by ID (cluster↔node,
  node↔node) — pod traffic is already covered regardless of which subnet the
  pod IP comes from.

### What *does* need care

- **Pod subnets must never get the `karpenter.sh/discovery` tag.** That tag
  tells Karpenter where it's allowed to launch node primary ENIs. Pod
  subnets exist purely to hand out pod IPs via `ENIConfig` (which references
  them by subnet ID directly, not by tag) — tagging them for discovery would
  let Karpenter mistakenly launch node ENIs into IP space meant for pods.
- **No `kubernetes.io/role/cni` tag needed either.** That tag belongs to a
  different, newer feature ("enhanced subnet discovery") that's an
  alternative to explicit `ENIConfig`s. Since this setup uses explicit
  `ENIConfig`s, that tag is irrelevant here — see
  [`kubernetes.io/role/cni` — why not needed here, and where it is](#kubernetesiorolecni--why-not-needed-here-and-where-it-is)
  below for the full explanation.
- The ALB security group rule that allowed `var.vpc_cidr` needs to also allow
  `var.pod_cidr`, or ALB traffic routed to pod IPs directly (`target-type:
  ip`) will be blocked.
- Existing pods do **not** move to the new range retroactively — only pods
  scheduled after the CNI picks up the new config get secondary-subnet IPs.
  A node roll (or at least bouncing the `aws-node` DaemonSet) is needed to
  fully cut over.
- Toggling `enable_pod_custom_networking` back to `false` later destroys the
  pod subnets and CIDR association, but doesn't retroactively move already
  running pods back — same caveat, opposite direction.

---

## The toggle

Everything in this setup is gated by one boolean. Off by default — nothing
is created unless you flip it.

```hcl
# variables.tf

variable "enable_pod_custom_networking" {
  description = "If true, provisions a secondary CIDR + dedicated pod subnets and configures VPC CNI custom networking so pod IPs come from that range instead of the node subnets. If false, none of this is created and pods use standard ENI-based IPs from the node subnets."
  type        = bool
  default     = false
}

variable "pod_cidr" {
  description = "Secondary CIDR block associated with the VPC, used exclusively for pod IPs when enable_pod_custom_networking is true."
  type        = string
  default     = "100.64.0.0/16"
}
```

---

## Terraform — VPC layer

```hcl
# vpc.tf

# Associate the secondary CIDR with the VPC
resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  count = var.enable_pod_custom_networking ? 1 : 0

  vpc_id     = aws_vpc.main.id
  cidr_block = var.pod_cidr
}

# One pod subnet per AZ (same AZ layout as your existing subnets)
resource "aws_subnet" "pods" {
  count = var.enable_pod_custom_networking ? var.public_subnet_count : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.pod_cidr, 4, count.index)  # /20s out of a /16 → 4096 pod IPs each
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-pods-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    # NOTE: deliberately NOT tagged with karpenter.sh/discovery —
    # these subnets are for pod IPs only, never for node placement.
  })

  depends_on = [aws_vpc_ipv4_cidr_block_association.pods]
}

# Pod subnets route out through the same NAT — reuse the existing private route table
resource "aws_route_table_association" "pods_assoc" {
  count = var.enable_pod_custom_networking ? var.public_subnet_count : 0

  subnet_id      = aws_subnet.pods[count.index].id
  route_table_id = aws_route_table.private.id
}
```

### ALB → node security group rule (update, not new)

```hcl
resource "aws_security_group_rule" "alb_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  security_group_id = aws_security_group.node.id
  cidr_blocks       = var.enable_pod_custom_networking ? [var.vpc_cidr, var.pod_cidr] : [var.vpc_cidr]
  description       = "Allow ALB to reach node ports"
}
```

---

## Terraform — EKS addon + ENIConfig layer

```hcl
# eks.tf

resource "aws_eks_addon" "eks-addons" {
  for_each      = { for idx, addon in var.addons : idx => addon }
  cluster_name  = aws_eks_cluster.eks.name
  addon_name    = each.value.name
  addon_version = each.value.version

  # attach role ONLY for EBS CSI
  service_account_role_arn = each.value.name == "aws-ebs-csi-driver" ? aws_iam_role.ebs_csi.arn : null

  # custom networking config ONLY for vpc-cni, ONLY when the toggle is on
  configuration_values = (each.value.name == "vpc-cni" && var.enable_pod_custom_networking) ? jsonencode({
    env = {
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
      ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
    }
  }) : null

  depends_on = [
    aws_eks_node_group.ondemand-node,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}

# One ENIConfig per AZ, only created when the toggle is on
resource "kubectl_manifest" "eniconfig" {
  count = var.enable_pod_custom_networking ? length(aws_subnet.pods) : 0

  yaml_body = <<-YAML
    apiVersion: crd.k8s.amazonaws.com/v1alpha1
    kind: ENIConfig
    metadata:
      name: ${data.aws_availability_zones.available.names[count.index]}
    spec:
      subnet: ${aws_subnet.pods[count.index].id}
      securityGroups:
        - ${aws_security_group.node.id}
  YAML

  depends_on = [aws_eks_addon.eks-addons]
}
```

### `kubectl_manifest` provider (required, add once if not already present)

```hcl
terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

provider "kubectl" {
  host                   = aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks.name]
  }
}
```

Whatever runs `terraform apply` needs AWS CLI v2 and credentials with access
to the cluster's Kubernetes API (your `access_config.authentication_mode =
"API"` block already covers this).

---

## Terraform — Karpenter controller setting

`RESERVED_ENIS` is **not** a `vpc-cni` addon setting — it's a Karpenter
**controller** setting, applied on the Karpenter Helm release itself. It
tells Karpenter's own scheduling math that one ENI slot per node is reserved
for the node and shouldn't count toward pod capacity.

```hcl
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # ... your existing set blocks ...

  set {
    name  = "settings.reservedENIs"
    value = var.enable_pod_custom_networking ? "1" : "0"
  }
}
```

> Confirm the exact value key (`settings.reservedENIs` vs an alternate path)
> against your installed chart version with:
> `helm show values oci://public.ecr.aws/karpenter --version <your_version> | grep -i reserved`
> — this key has shifted across Karpenter major versions.

Nothing else in your Karpenter `NodePool` / `EC2NodeClass` manifests needs to
change. Karpenter nodes get `topology.kubernetes.io/zone` set automatically
by AWS, which is all `ENI_CONFIG_LABEL_DEF` needs to match them to the
correct `ENIConfig`.

---

## `kubernetes.io/role/cni` — why not needed here, and where it is

There are **two separate, mutually-exclusive-by-precedence mechanisms** for
expanding pod IP space on EKS, and `kubernetes.io/role/cni` belongs to the
*other* one — not the one this setup uses.

### Why this setup doesn't need it

This setup uses **custom networking**, where the CNI finds a pod subnet by
reading an explicit subnet ID off an `ENIConfig` object (matched to the node
via its AZ label). No tag lookup is involved — the subnet is named directly
in the CR already created above:

```yaml
spec:
  subnet: ${aws_subnet.pods[count.index].id}   # ← explicit ID, not a tag lookup
```

Tagging the pod subnets with `kubernetes.io/role/cni` in this setup would
simply do nothing, since custom networking doesn't consult that tag.

### Where it *is* needed — the alternative mechanism

`kubernetes.io/role/cni` belongs to **enhanced subnet discovery**, a simpler,
newer feature (VPC CNI ≥ 1.18, on by default since then via
`ENABLE_SUBNET_DISCOVERY=true`) that solves the same IP-exhaustion problem
without `ENIConfig` CRDs at all:

> The VPC CNI automatically discovers subnets in the same VPC and
> Availability Zone as the node, then uses them to create secondary ENIs and
> allocate Pod IP addresses. This expands the available IP address space
> without manual ENIConfig configuration.
> — [docs.aws.amazon.com/eks/.../cni-subnet-selection](https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html)

You'd reach for this path instead of the one in this README if:
- You just want more pod IPs in the *same AZs your nodes already run in* and
  don't need pods on a different security group than the node.
- You'd rather tag-and-forget than manage per-AZ `ENIConfig` objects.
- You're OK with the CNI auto-discovering *any* similarly-tagged subnet in
  the node's AZ, rather than pinning one specific subnet per AZ.

It even works with a secondary CIDR the same way this setup does — just
tagged instead of CRD-based:

> Once the VPC CIDR range is exhausted, we associate a secondary CIDR to the
> VPC, and then we create the VPC subnets with the `kubernetes.io/role/cni`
> tag so that VPC CNI can automatically discover and use the new subnets to
> allocate the Pod IP addresses.
> — [aws.amazon.com/blogs/containers/.../enhanced-subnet-discovery](https://aws.amazon.com/blogs/containers/amazon-vpc-cni-introduces-enhanced-subnet-discovery/)

### Why this setup uses custom networking instead of tagging

Custom networking gives two things tagging can't:
1. **A different security group for pods than the node** — the `ENIConfig`
   here references `aws_security_group.node.id`, but it could point at a
   dedicated pod SG later without touching the tagging mechanism at all.
2. **Explicit, predictable subnet-to-AZ pinning** — one exact subnet per AZ,
   versus "whichever tagged subnet the CNI happens to discover in that AZ."

If both features are ever enabled at once (a subnet tagged **and** an
`ENIConfig` for that AZ), AWS is explicit that custom networking wins:

> Custom networking takes precedence when both features are enabled.
> — [docs.aws.amazon.com/eks/.../cni-subnet-selection](https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html)

So tagging the pod subnets with `kubernetes.io/role/cni` alongside the
existing `ENIConfig`s would be redundant, not additive — safe to leave off.

---

## Rollout checklist

1. Set `enable_pod_custom_networking = true` and `terraform apply`.
2. Verify the secondary CIDR association, pod subnets, and `ENIConfig`s were
   created (`kubectl get eniconfig`).
3. Confirm the `aws-node` DaemonSet picked up the new env vars:
   ```
   kubectl describe ds aws-node -n kube-system | grep -E "CUSTOM_NETWORK|ENI_CONFIG_LABEL"
   ```
4. Roll existing nodes (or at minimum restart `aws-node` pods) so already-
   running nodes start handing out pod IPs from the new subnets — existing
   pods won't move on their own.
5. Confirm Karpenter's Helm values show `reservedENIs: "1"` and that new
   nodes it provisions report accurate max-pod counts.
6. Watch pod IP allocation shift to the `100.64.x.x` range for pods
   scheduled after the rollout.

---

## References

- Karpenter — NodeClasses / VPC CNI Custom Networking support & `RESERVED_ENIS`:
  https://karpenter.sh/docs/concepts/nodeclasses/
- Karpenter — Settings reference (`RESERVED_ENIS` / `--reserved-enis`):
  https://karpenter.sh/docs/reference/settings/
- Karpenter — subnet discovery via `karpenter.sh/discovery` tag (GitHub issue):
  https://github.com/aws/karpenter-provider-aws/issues/632
- AWS EKS — Configure subnet selection for Pod IP addresses (`kubernetes.io/role/cni`
  vs. custom networking precedence):
  https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html
- AWS Blog — Amazon VPC CNI Enhanced Subnet Discovery (secondary CIDR + IP
  exhaustion background):
  https://aws.amazon.com/blogs/containers/amazon-vpc-cni-introduces-enhanced-subnet-discovery/
- Amazon VPC CNI — `ENI_CONFIG_LABEL_DEF` / `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG`
  env var reference:
  https://github.com/aws/amazon-vpc-cni-k8s
