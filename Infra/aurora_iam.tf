# ==============================================================================
# AURORA (PostgreSQL) — IAM ROLE FOR SERVICE ACCOUNT (IRSA)
# ==============================================================================
# How IAM DB authentication works in PostgreSQL (different from MySQL):
#
#   MySQL  → CREATE USER ... IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS'
#   PostgreSQL → CREATE USER app_user; GRANT rds_iam TO app_user;
#
# Runtime token flow (same for both engines):
#   1. Pod's ServiceAccount is annotated with this role's ARN.
#   2. EKS OIDC webhook injects a projected OIDC token into the pod.
#   3. AWS SDK exchanges the OIDC token for IAM credentials
#      (AssumeRoleWithWebIdentity).
#   4. SDK calls rds:GenerateAuthToken → 15-minute auth token.
#   5. Pod opens psycopg2/pg/pgx connection:
#        host=<aurora-endpoint>  user=app_user  password=<token>  sslmode=require
#
# No static password ever leaves AWS. CloudTrail logs every token generation.
# ==============================================================================

locals {
  aurora_irsa_enabled = var.aurora_enabled
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# IAM POLICY — rds-db:connect scoped to the specific cluster + DB username
#
# ARN format for PostgreSQL:
#   arn:aws:rds-db:<region>:<account>:dbuser:<cluster-resource-id>/<db-username>
#
# cluster_resource_id (e.g. "cluster-ABCDEFGHIJ") is the stable resource ID
# that Aurora assigns; it is NOT the cluster identifier/endpoint name.
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "aurora_connect" {
  count = local.aurora_irsa_enabled ? 1 : 0

  name        = "${var.cluster_name}-aurora-connect-policy"
  description = "Allow rds-db:connect as ${var.aurora_app_db_user} on the Aurora PostgreSQL cluster"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "rds-db:connect"
      Resource = [
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_rds_cluster.aurora[0].cluster_resource_id}/${var.aurora_app_db_user}"
      ]
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-connect-policy"
  })
}

# ------------------------------------------------------------------------------
# IRSA ROLE — trusts the cluster OIDC provider, scoped to ONE ServiceAccount
# in ONE namespace. Same pattern as alb_iam.tf and the ebs_csi role in eks.tf.
# ------------------------------------------------------------------------------
resource "aws_iam_role" "aurora_app" {
  count = local.aurora_irsa_enabled ? 1 : 0

  name = "${var.cluster_name}-aurora-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # Scoped to exactly one ServiceAccount in one namespace.
          # Any other SA that references this role will be rejected by STS.
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:${var.aurora_app_service_account_namespace}:${var.aurora_app_service_account_name}"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-app-role"
  })
}

resource "aws_iam_role_policy_attachment" "aurora_app_connect" {
  count = local.aurora_irsa_enabled ? 1 : 0

  role       = aws_iam_role.aurora_app[0].name
  policy_arn = aws_iam_policy.aurora_connect[0].arn
}

# ------------------------------------------------------------------------------
# OPTIONAL: Grant the IRSA role read access to the master Secrets Manager secret.
# Useful for migration Jobs (alembic, flyway, django migrate) that need the
# master user's DDL privileges.
# Set var.aurora_app_read_master_secret = true to enable.
# ------------------------------------------------------------------------------
resource "aws_iam_policy" "aurora_read_master_secret" {
  count = local.aurora_irsa_enabled && var.aurora_app_read_master_secret ? 1 : 0

  name        = "${var.cluster_name}-aurora-read-master-secret"
  description = "Allow reading the auto-managed Aurora master password secret"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_rds_cluster.aurora[0].master_user_secret[0].secret_arn
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "aurora_app_read_master_secret" {
  count = local.aurora_irsa_enabled && var.aurora_app_read_master_secret ? 1 : 0

  role       = aws_iam_role.aurora_app[0].name
  policy_arn = aws_iam_policy.aurora_read_master_secret[0].arn
}
