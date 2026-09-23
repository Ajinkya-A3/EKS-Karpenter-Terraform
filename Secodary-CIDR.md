# Secondary CIDR — Dealing with IP Exhaustion

This document describes the **VPC CNI enhanced subnet discovery** setup used
to give pods extra IP space from a secondary CIDR, separate from the primary
VPC CIDR, to solve IP exhaustion in the node subnets. It's fully
toggle-controlled via `enable_pod_subnet_discovery` — when off, nothing
described here is created and the cluster behaves exactly as it did before.

> This uses **subnet tagging (enhanced subnet discovery)**, not
> `ENIConfig`-based custom networking. See
> [Why tagging instead of `ENIConfig`](#why-tagging-instead-of-eniconfig)
> below for why, and where you'd reach for the other approach instead.

---

## Why this exists

Pods on EKS normally get IP addresses from the **same subnet as the node's
primary ENI** — the VPC CNI attaches secondary ENIs in that same subnet and
hands their IPs to pods. On a `/24` per-AZ subnet, that space gets consumed
fast once you're running dozens of pods per node across several nodes — you
run out of pod IPs long before you run out of compute.

**Enhanced subnet discovery** fixes this with almost no moving parts: tag
extra subnets, and the CNI automatically starts creating secondary ENIs in
them once the node's own subnet runs low.

---

## How it works, end to end

1. A secondary CIDR (`100.64.0.0/16` by default — the CGNAT range, chosen
   because it can never collide with RFC1918 space used by peered VPCs or
   on-prem networks) is associated with the VPC.
2. Extra subnets are carved out of that CIDR, one per AZ, and tagged
   `kubernetes.io/role/cni`.
3. The `vpc-cni` addon has `ENABLE_SUBNET_DISCOVERY=true` set (this is
   actually the **default** on VPC CNI ≥ 1.18.0 — the toggle here just makes
   it explicit and tied to your feature flag).
4. When a node's primary-subnet IP space runs low, the CNI automatically
   discovers any tagged subnet in the **same VPC and same AZ** as the node
   and creates new secondary ENIs there instead — no `ENIConfig` objects, no
   per-AZ custom resources, nothing referencing subnet IDs by hand.

### What does *not* need to change

- **Karpenter NodePools / EC2NodeClass** — untouched. Karpenter nodes launch
  into the same private subnets as before (selected via the
  `karpenter.sh/discovery` tag).
- **Karpenter's `RESERVED_ENIS` setting — not needed for this approach.**
  Unlike custom networking, enhanced subnet discovery doesn't carve out a
  dedicated "node-only" ENI — the primary ENI keeps handing out pod IPs
  exactly as before, and the *additional* ENIs the CNI creates in tagged
  subnets are pure extra capacity. Karpenter's default max-pods formula
  (`# of ENIs × (# of IPv4 per ENI − 1) + 2`) is already accurate here, so
  there's nothing to reserve or subtract.
- **Node security group rules** that reference the SG by ID (cluster↔node,
  node↔node) — pod traffic is already covered regardless of which subnet the
  pod IP comes from.

### What *does* need care

- **Tagged subnets must never get the `karpenter.sh/discovery` tag.** That
  tag tells Karpenter where it's allowed to launch node primary ENIs. The
  extra pod-IP subnets exist purely to give the CNI more IP headroom —
  tagging them for Karpenter discovery would let Karpenter mistakenly launch
  node ENIs into that space too.
- **Requires VPC CNI ≥ 1.18.0** and **EKS ≥ 1.25**. Confirm your `vpc-cni`
  addon version before enabling.
- **The tag only affects *new* ENI creation.** Existing secondary ENIs
  already attached to a node keep using their original subnet — this
  doesn't retroactively move already-running pods. A node roll (or waiting
  for natural node churn) is needed for nodes to actually start creating
  ENIs in the new subnets.
- The ALB security group rule that allowed `var.vpc_cidr` needs to also
  allow `var.pod_cidr`, or ALB traffic routed to pod IPs directly
  (`target-type: ip`) will be blocked once pods start getting IPs from the
  secondary range.
- Toggling `enable_pod_subnet_discovery` back to `false` later destroys the
  tagged subnets and CIDR association — any pods still using IPs from that
  range at the time will need to be rescheduled.

---

## The toggle

Everything in this setup is gated by one boolean. Off by default — nothing
is created unless you flip it.

```hcl
# variables.tf

variable "enable_pod_subnet_discovery" {
  description = "If true, provisions a secondary CIDR + tagged pod subnets and enables VPC CNI enhanced subnet discovery so pods can get IPs from that range once node subnets run low. If false, none of this is created and pods use standard ENI-based IPs from the node subnets."
  type        = bool
  default     = false
}

variable "pod_cidr" {
  description = "Secondary CIDR block associated with the VPC, used for extra pod IP capacity when enable_pod_subnet_discovery is true."
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
  count = var.enable_pod_subnet_discovery ? 1 : 0

  vpc_id     = aws_vpc.main.id
  cidr_block = var.pod_cidr
}

# One extra pod-IP subnet per AZ, tagged for enhanced subnet discovery
resource "aws_subnet" "pods" {
  count = var.enable_pod_subnet_discovery ? var.public_subnet_count : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.pod_cidr, 4, count.index)  # /20s out of a /16 → 4096 IPs each
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-pods-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"

    # This is the tag enhanced subnet discovery actually looks for.
    "kubernetes.io/role/cni" = "1"

    # NOTE: deliberately NOT tagged with karpenter.sh/discovery —
    # this subnet is for pod IP overflow only, never for node placement.
  })

  depends_on = [aws_vpc_ipv4_cidr_block_association.pods]
}

# Route out through the same NAT the private subnets already use
resource "aws_route_table_association" "pods_assoc" {
  count = var.enable_pod_subnet_discovery ? var.public_subnet_count : 0

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
  cidr_blocks       = var.enable_pod_subnet_discovery ? [var.vpc_cidr, var.pod_cidr] : [var.vpc_cidr]
  description       = "Allow ALB to reach node ports"
}
```

---

## Terraform — EKS addon layer

```hcl
# eks.tf

resource "aws_eks_addon" "eks-addons" {
  for_each      = { for idx, addon in var.addons : idx => addon }
  cluster_name  = aws_eks_cluster.eks.name
  addon_name    = each.value.name
  addon_version = each.value.version

  # attach role ONLY for EBS CSI
  service_account_role_arn = each.value.name == "aws-ebs-csi-driver" ? aws_iam_role.ebs_csi.arn : null

  # enable subnet discovery ONLY for vpc-cni, ONLY when the toggle is on
  configuration_values = (each.value.name == "vpc-cni" && var.enable_pod_subnet_discovery) ? jsonencode({
    env = {
      ENABLE_SUBNET_DISCOVERY = "true"
    }
  }) : null

  depends_on = [
    aws_eks_node_group.ondemand-node,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}
```

That's the entire addon change. No `ENIConfig` custom resources, no
`kubectl_manifest` resources, and no `kubectl` provider needed for this
feature — enhanced subnet discovery is driven entirely by subnet tags, which
Terraform already manages as native AWS resources.

> `ENABLE_SUBNET_DISCOVERY=true` is actually the CNI's own default on
> version ≥ 1.18.0. Setting it explicitly here just ties the behavior to
> your `enable_pod_subnet_discovery` toggle so the addon config stays
> declarative and self-documenting, and so it's explicitly `false`-able if
> you ever need to turn discovery off without touching the addon version.

---

## Rollout checklist

1. Confirm your `vpc-cni` addon version is ≥ 1.18.0 and the cluster is on
   EKS ≥ 1.25.
2. Set `enable_pod_subnet_discovery = true` and `terraform apply`.
3. Verify the secondary CIDR association and tagged subnets were created:
   ```
   aws ec2 describe-subnets --filters "Name=tag:kubernetes.io/role/cni,Values=1"
   ```
4. Confirm the `aws-node` DaemonSet picked up the setting:
   ```
   kubectl describe ds aws-node -n kube-system | grep ENABLE_SUBNET_DISCOVERY
   ```
5. No forced node roll is strictly required — nodes will start creating
   secondary ENIs in the tagged subnets automatically once their primary
   subnet runs low on IPs. To see the effect sooner, roll nodes or wait for
   natural Karpenter consolidation/replacement.
6. Watch pod IP allocation shift to the `100.64.x.x` range as node subnets
   fill up.

---

## Why tagging instead of `ENIConfig`

There are two mutually-exclusive-by-precedence mechanisms for expanding pod
IP space on EKS. This README now uses **enhanced subnet discovery**
(tagging) rather than **custom networking** (`ENIConfig` CRDs). Both solve
the same IP-exhaustion problem; they differ in mechanism and trade-offs.

**Enhanced subnet discovery (this setup):**
- Tag subnets, done — no CRDs, no per-AZ custom resources, no `kubectl`
  Terraform provider needed.
- The CNI automatically discovers *any* similarly-tagged subnet in the
  node's AZ and uses it once the primary subnet is low on IPs.
- Pods keep the **same security group as the node** — there's no way to
  give pods a distinct SG under this mechanism.
- No ENI is reserved from pod use — Karpenter's default max-pods math
  applies unchanged.

**Custom networking (the alternative, not used here):**
- Requires an `ENIConfig` custom resource per AZ, explicitly naming a
  subnet ID and security group.
- Gives pods a **different security group than the node**, useful for
  pod-level network policy separate from node rules.
- Pins one exact subnet per AZ rather than letting the CNI discover any
  tagged subnet.
- The node's primary ENI stops serving pod IPs entirely, so Karpenter needs
  `RESERVED_ENIS=1` on its controller settings to keep its max-pods
  calculation accurate.

AWS's own precedence note: if a subnet is tagged **and** an `ENIConfig`
exists for that AZ, custom networking wins — the two aren't meant to be
combined for the same AZ:

> Custom networking takes precedence when both features are enabled.
> — [docs.aws.amazon.com/eks/.../cni-subnet-selection](https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html)

Pick custom networking instead of this README's approach only if you
specifically need pods on a different security group than their node, or
need hard, predictable pinning of one exact subnet per AZ rather than
CNI auto-discovery.

---

## References

- AWS EKS — Configure subnet selection for Pod IP addresses (enhanced
  subnet discovery vs. custom networking, precedence, tag behavior):
  https://docs.aws.amazon.com/eks/latest/userguide/cni-subnet-selection.html
- AWS — Amazon VPC CNI now supports automatic subnet discovery (launch
  announcement, VPC CNI ≥ 1.18.0, EKS ≥ 1.25 requirement):
  https://aws.amazon.com/about-aws/whats-new/2024/04/amazon-vpc-cni-automatic-subnet-discovery/
- AWS Blog — Amazon VPC CNI introduces Enhanced Subnet Discovery (secondary
  CIDR + IP exhaustion background, tagging walkthrough):
  https://aws.amazon.com/blogs/containers/amazon-vpc-cni-introduces-enhanced-subnet-discovery/
- AWS re:Post — How to resolve and monitor insufficient IP addresses in EKS
  clusters (step-by-step: enable discovery, tag subnets):
  https://repost.aws/knowledge-center/eks-resolve-cluster-ip-address-issues
- Karpenter — NodeClasses / `RESERVED_ENIS` (for context on why it's *not*
  needed for this approach, only for custom networking / Security Groups
  for Pods):
  https://karpenter.sh/docs/concepts/nodeclasses/
- Karpenter — Settings reference (`RESERVED_ENIS` / `--reserved-enis`):
  https://karpenter.sh/docs/reference/settings/
- Karpenter — subnet discovery via `karpenter.sh/discovery` tag (GitHub
  issue, for the node-subnet side of tagging):
  https://github.com/aws/karpenter-provider-aws/issues/632