# =========================================
# EKS CLUSTER INFO
# =========================================
output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.eks.version
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}

# =========================================
# KUBECTL CONFIG (IMPORTANT)
# =========================================
output "kubectl_config" {
  value = {
    cluster_name = aws_eks_cluster.eks.name
    region       = var.region
  }
}

# =========================================
# NODE GROUP INFO
# =========================================
output "node_group_name" {
  value = aws_eks_node_group.ondemand-node.node_group_name
}

output "node_group_status" {
  value = aws_eks_node_group.ondemand-node.status
}

# =========================================
# NETWORKING
# =========================================
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnets" {
  value = aws_subnet.public[*].id
}

output "internet_gateway_id" {
  value = aws_internet_gateway.igw.id
}

# =========================================
# SECURITY GROUPS
# =========================================
output "eks_cluster_sg" {
  value = aws_security_group.eks_cluster.id
}

output "node_sg" {
  value = aws_security_group.node.id
}

# =========================================
# IAM ROLES
# =========================================
output "eks_cluster_role_arn" {
  value = aws_iam_role.eks_cluster.arn
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "cluster_ca" {
  description = "Base64 encoded cluster CA certificate"
  value       = aws_eks_cluster.eks.certificate_authority[0].data
  sensitive   = true
}

# =========================================
# ALB Controller
# =========================================

output "alb_controller_role_arn" {
  value = aws_iam_role.alb.arn
}


# =========================================
# Karpenter IAM Roles and SQS Queue
# =========================================

output "karpenter_node_role_arn" {
  description = "ARN of the Karpenter node IAM role"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  description = "ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_sqs_queue_url" {
  description = "URL of the Karpenter interruption SQS queue"
  value       = aws_sqs_queue.karpenter_interruption.url
}

output "karpenter_sqs_queue_arn" {
  description = "ARN of the Karpenter interruption SQS queue"
  value       = aws_sqs_queue.karpenter_interruption.arn
}

output "karpenter_sqs_queue_name" {
  description = "Name of the Karpenter interruption SQS queue"
  value       = aws_sqs_queue.karpenter_interruption.name
}

# =========================================
# AURORA SERVERLESS v2 (PostgreSQL)
# =========================================

output "aurora_cluster_endpoint" {
  description = "Writer endpoint — use as the host in your PostgreSQL connection string."
  value       = try(aws_rds_cluster.aurora[0].endpoint, null)
}

output "aurora_cluster_reader_endpoint" {
  description = "Reader endpoint — use for read replicas (if/when you add reader instances)."
  value       = try(aws_rds_cluster.aurora[0].reader_endpoint, null)
}

output "aurora_cluster_port" {
  description = "PostgreSQL listener port (5432)."
  value       = try(aws_rds_cluster.aurora[0].port, null)
}

output "aurora_database_name" {
  description = "Initial database created inside the cluster."
  value       = try(aws_rds_cluster.aurora[0].database_name, null)
}

output "aurora_cluster_resource_id" {
  description = "Cluster resource ID (cluster-XXXX...). Appears in the rds-db:connect IAM ARN."
  value       = try(aws_rds_cluster.aurora[0].cluster_resource_id, null)
}

output "aurora_master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the auto-managed master credentials."
  value       = try(aws_rds_cluster.aurora[0].master_user_secret[0].secret_arn, null)
  sensitive   = true
}

output "aurora_security_group_id" {
  description = "Aurora SG — ingress TCP/5432 from EKS node SG only."
  value       = try(aws_security_group.aurora[0].id, null)
}

# ---- IRSA outputs (needed to annotate the K8s ServiceAccount) ----

output "aurora_app_irsa_role_arn" {
  description = "Annotate your ServiceAccount with: eks.amazonaws.com/role-arn=<this>"
  value       = try(aws_iam_role.aurora_app[0].arn, null)
}

output "aurora_app_db_user" {
  description = "PostgreSQL role the app authenticates as via IAM. Create with: CREATE USER app_user; GRANT rds_iam TO app_user;"
  value       = var.aurora_app_db_user
}

output "aurora_app_service_account" {
  description = "Kubernetes ServiceAccount (namespace/name) bound to the Aurora IRSA role."
  value       = try("${var.aurora_app_service_account_namespace}/${var.aurora_app_service_account_name}", null)
}