resource "aws_eks_cluster" "eks" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    # Pass both public and private subnets so the EKS control plane
    # ENIs are spread across AZs inside the VPC.
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_public_access  = true  # keeps kubectl working from your machine
    endpoint_private_access = true  # nodes in private subnets reach the API internally
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(var.tags, {
    Name = var.cluster_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]
}

# =========================
# OIDC Provider
# =========================
data "tls_certificate" "eks" {
  url        = aws_eks_cluster.eks.identity[0].oidc[0].issuer
  depends_on = [aws_eks_cluster.eks]
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.eks.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

# =========================
# Launch Template
# =========================
resource "aws_launch_template" "node" {
  name_prefix   = "eks-node"
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.node.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name                                        = "${var.cluster_name}-node"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name                                        = "${var.cluster_name}-node-volume"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = merge(var.tags, {
      Name                                        = "${var.cluster_name}-node-eni"
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    })
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-launch-template"
  })
}

# =========================
# Node Group (ON DEMAND) — private subnets
# Nodes launch into private subnets so they have no public IPs.
# Outbound internet access (ECR pulls, SSM, etc.) goes via the NAT Gateway.
# =========================
resource "aws_eks_node_group" "ondemand-node" {
  cluster_name  = aws_eks_cluster.eks.name
  node_role_arn = aws_iam_role.node.arn
  subnet_ids    = aws_subnet.private[*].id  # ← private subnets only
  capacity_type = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  update_config {
    max_unavailable = 1 # only 1 of nodes can be unavailable at once
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = {
    "type" = "ondemand"
    "role"      = "system"          # ← clear role label
    "node-type" = "managed"         # ← distinguishes from Karpenter nodes
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ondemand-ng"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_policies,
    aws_nat_gateway.nat
  ]

  lifecycle {
    ignore_changes = [
      scaling_config[0].desired_size  # prevent Terraform from reverting autoscaler changes
    ]
  }
}

# =========================
# Addons
# =========================
resource "aws_eks_addon" "eks-addons" {
  for_each      = { for idx, addon in var.addons : idx => addon }
  cluster_name  = aws_eks_cluster.eks.name
  addon_name    = each.value.name
  addon_version = each.value.version

  # attach role ONLY for EBS CSI
  service_account_role_arn = each.value.name == "aws-ebs-csi-driver" ? aws_iam_role.ebs_csi.arn : null

  depends_on = [
    aws_eks_node_group.ondemand-node,
    aws_iam_role_policy_attachment.ebs_csi_policy
  ]
}

# =========================
# IAM Role for EBS CSI Driver
# =========================

resource "aws_iam_role" "ebs_csi" {
  name = "ebs-csi-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      },
      Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}


resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}