# =========================
# EC2NodeClass — Default (used by all NodePools)
# =========================
resource "kubectl_manifest" "karpenter_ec2_node_class_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      # -----------------------------------------------
      # IAM Role — must already exist, created by your
      # Karpenter IAM Terraform. This role is what the
      # EC2 NODE itself uses (not Karpenter controller).
      # It needs: AmazonEKSWorkerNodePolicy,
      #           AmazonEC2ContainerRegistryReadOnly,
      #           AmazonEKS_CNI_Policy
      # -----------------------------------------------
      role: "KarpenterNodeRole-${local.cluster_name}"

      # -----------------------------------------------
      # AMI Selection — al2023@latest is the right call.
      # Karpenter will automatically pick:
      #   al2023-arm64 for arm64 nodes
      #   al2023-x86_64 for amd64 nodes
      # You do NOT need separate NodeClasses per arch —
      # the alias handles both automatically.
      # Other options:
      #   al2@latest         → Amazon Linux 2 (older)
      #   bottlerocket@latest → security-focused, minimal OS
      #   windows2022@latest  → Windows nodes
      # -----------------------------------------------
      amiSelectorTerms:
        - alias: "al2023@latest"

      # -----------------------------------------------
      # Subnet Discovery — Karpenter finds your subnets
      # by this tag. Make sure your PRIVATE subnets have
      # this tag set in Terraform:
      #   "karpenter.sh/discovery" = local.cluster_name
      # IMPORTANT: Only tag private subnets, never public.
      # Karpenter should never launch nodes in public subnets.
      # -----------------------------------------------
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${local.cluster_name}"

      # -----------------------------------------------
      # Security Group Discovery — same tag approach.
      # Tag your node security group with this.
      # Typically the EKS-managed node SG already has it
      # if you used the EKS Terraform module.
      # -----------------------------------------------
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${local.cluster_name}"

      # -----------------------------------------------
      # Root EBS Volume — al2023 default is 20GB which
      # is too small for production. Set based on your
      # image sizes. 50GB covers most workloads.
      # gp3 is cheaper and faster than gp2 — always use gp3.
      # -----------------------------------------------
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            iops: 3000          # baseline for gp3, free up to 3000
            throughput: 125     # MB/s, free up to 125 on gp3
            encrypted: true     # always encrypt at rest
            deleteOnTermination: true


      # -----------------------------------------------
      # Tags — applied to the EC2 instance itself.
      # Add your cost allocation tags here.
      # -----------------------------------------------
      tags:
        karpenter.sh/discovery: "${local.cluster_name}"
        ManagedBy: "karpenter"
        Cluster: "${local.cluster_name}"
  YAML

  depends_on = [helm_release.karpenter]
}



