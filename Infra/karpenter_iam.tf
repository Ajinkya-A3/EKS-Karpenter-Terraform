# =========================
# EKS Access Entry for Karpenter Node Role
# (your cluster uses authentication_mode = "API", so no aws-auth ConfigMap needed)
# =========================
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.eks]
}

# =========================
# Karpenter Node IAM Role
# =========================
resource "aws_iam_role" "karpenter_node" {
  name = "KarpenterNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/${each.value}"
}

# =========================
# Karpenter Controller IAM Role (IRSA)
# =========================
resource "aws_iam_role" "karpenter_controller" {
  name = "KarpenterControllerRole-${var.cluster_name}"

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
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com",
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:${var.karpenter_namespace}:karpenter"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "karpenter_controller_policy" {
  name = "KarpenterControllerPolicy-${var.cluster_name}"
  role = aws_iam_role.karpenter_controller.id

  policy = templatefile("${path.module}/policies/karpenter-controller-policy.json", {
    cluster_name            = var.cluster_name
    region                  = var.region
    karpenter_node_role_arn = aws_iam_role.karpenter_node.arn
    eks_cluster_arn         = aws_eks_cluster.eks.arn
    sqs_queue_arn           = aws_sqs_queue.karpenter_interruption.arn
  })
}