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

# =========================================
# AURORA SERVERLESS v2 (PostgreSQL)
# =========================================

variable "aurora_enabled" {
  description = "Master switch for the Aurora Serverless v2 (PostgreSQL) cluster and its IRSA role."
  type        = bool
  default     = true
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version. Must be 16.3+ / 15.7+ / 14.12+ / 13.15+ for scale-to-zero. Latest stable across all regions as of Apr 2026: 16.6"
  type        = string
  default     = "16.6"
}

variable "aurora_pg_family" {
  description = "Parameter group family. Must match major version: aurora-postgresql16 for 16.x, aurora-postgresql17 for 17.x."
  type        = string
  default     = "aurora-postgresql16"
}

variable "aurora_database_name" {
  description = "Initial database created inside the cluster."
  type        = string
  default     = "appdb"
}

variable "aurora_master_username" {
  description = "Master DB superuser. Password is auto-managed in Secrets Manager — never stored in tfstate."
  type        = string
  default     = "postgres"
}

variable "aurora_min_capacity" {
  description = "Minimum Aurora Capacity Units. Set to 0 to enable auto-pause (scale-to-zero). Typical: 0 (dev) or 0.5 (prod)."
  type        = number
  default     = 0
}

variable "aurora_max_capacity" {
  description = "Maximum Aurora Capacity Units. Each ACU ~= 2 GiB RAM + proportional CPU/network."
  type        = number
  default     = 2
}

variable "aurora_seconds_until_auto_pause" {
  description = "Idle seconds before auto-pause (scale-to-zero). Only effective when min_capacity = 0. Range: 300–86400."
  type        = number
  default     = 300
}

variable "aurora_backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "aurora_deletion_protection" {
  description = "Prevent `terraform destroy` from deleting the cluster. Keep false for dev, true for prod."
  type        = bool
  default     = false
}

variable "aurora_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Keep true for dev, false for prod."
  type        = bool
  default     = true
}

variable "aurora_log_min_duration_ms" {
  description = "Log queries slower than N ms to CloudWatch (log_min_duration_statement). Set -1 to disable."
  type        = number
  default     = 1000
}

# ---- IRSA / IAM DB auth ----

variable "aurora_app_db_user" {
  description = "PostgreSQL role that pods authenticate as via IAM tokens. Create it in DB after first apply: CREATE USER app_user; GRANT rds_iam TO app_user; (see AURORA_CONNECT.md)"
  type        = string
  default     = "app_user"
}

variable "aurora_app_service_account_namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume the Aurora IRSA role."
  type        = string
  default     = "default"
}

variable "aurora_app_service_account_name" {
  description = "Kubernetes ServiceAccount name allowed to assume the Aurora IRSA role."
  type        = string
  default     = "app-db-access"
}

variable "aurora_app_read_master_secret" {
  description = "Also grant the IRSA role read access to the Secrets Manager master secret. Keep false for app pods; enable only for migration Jobs."
  type        = bool
  default     = false
}
