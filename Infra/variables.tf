variable "region" {
  default = "ap-south-1"
}

variable "cluster_name" {
  default = "demo"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "cluster_version" {
  default = 1.35
}


variable "instance_type" {
  default = "t3.medium"
}

variable "desired_size" {
  default = 2
}

variable "max_size" {
  default = 3
}

variable "min_size" {
  default = 1
}

variable "addons" {
  default = [
    {
      name    = "vpc-cni"
      version = "v1.21.1-eksbuild.1"
    },
    {
      name    = "coredns"
      version = "v1.13.2-eksbuild.3"
    },
    {
      name    = "kube-proxy"
      version = "v1.35.0-eksbuild.2"
    },
    {
      name    = "aws-ebs-csi-driver"
      version = "v1.57.1-eksbuild.1"
    }
  ]
}

variable "public_subnet_count" {
  default = 2
}

variable "tags" {
  type = map(string)
  default = {
    Environment = "dev"
    Terraform   = "true"
  }
}

variable "karpenter_namespace" {
  description = "namespace for karpenter"
  default     = "karpenter"
}


# =========================================
# VPC ENDPOINT TOGGLES
# Gateway endpoints (s3, dynamodb) are always free — always on.
# Interface endpoints cost ~$7-8/month per endpoint (across 2 AZs).
#
# Recommended minimum (true):  ecr_api, ecr_dkr, ec2, sts, sqs
# Optional (review before enabling): eks, ssm
# =========================================

variable "enable_endpoint_ecr_api" {
  description = "Enable ECR API interface endpoint. Required for image manifest auth. Keep true if using ECR."
  type        = bool
  default     = true
}

variable "enable_endpoint_ecr_dkr" {
  description = "Enable ECR DKR interface endpoint. Required for image layer pulls. Keep true if using ECR."
  type        = bool
  default     = true
}

variable "enable_endpoint_ec2" {
  description = "Enable EC2 interface endpoint. Required for Karpenter (RunInstances, CreateFleet, TerminateInstances)."
  type        = bool
  default     = true
}

variable "enable_endpoint_sts" {
  description = "Enable STS interface endpoint. Required for IRSA token exchange (Karpenter, ALB controller, EBS CSI)."
  type        = bool
  default     = true
}

variable "enable_endpoint_sqs" {
  description = "Enable SQS interface endpoint. Required for Karpenter interruption queue (Spot). Set false only if not using Spot."
  type        = bool
  default     = true
}

variable "enable_endpoint_eks" {
  description = "Enable EKS interface endpoint. Optional — kubelet falls back to public endpoint. Saves ~$14/month if disabled."
  type        = bool
  default     = false
}

variable "enable_endpoint_ssm" {
  description = "Enable SSM Session Manager endpoints (ssm + ssmmessages + ec2messages). Only needed for node shell access via SSM. Saves ~$43/month if disabled."
  type        = bool
  default     = false
}
