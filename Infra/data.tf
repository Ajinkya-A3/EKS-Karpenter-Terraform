data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# EKS cluster data (used for kube + helm auth)
data "aws_eks_cluster" "eks" {
  name = aws_eks_cluster.eks.name
}

data "aws_eks_cluster_auth" "eks" {
  name = aws_eks_cluster.eks.name
}