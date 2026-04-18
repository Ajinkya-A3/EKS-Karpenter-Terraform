# ==============================================================================
# AURORA SERVERLESS v2  —  PostgreSQL-compatible
# ==============================================================================
# Design choices:
#   - engine              : aurora-postgresql (NOT aurora-mysql)
#   - engine_mode         : "provisioned"  — Serverless v2 always uses this.
#                           The "serverless" comes from instance_class = db.serverless
#   - port                : 5432 (Postgres default)
#   - subnet group        : private subnets only — no public IPs, no IGW path
#   - security group      : ingress TCP/5432 from EKS node SG only
#   - SSL                 : rds.force_ssl = 1 in the parameter group
#   - credentials         : manage_master_user_password = true — AWS auto-rotates
#                           the master password in Secrets Manager; no password in tfstate
#   - IAM DB auth         : iam_database_authentication_enabled = true — app pods
#                           authenticate with IRSA tokens (see aurora_iam.tf)
#   - scale-to-zero       : min_capacity = 0 — auto-pause after idle.
#                           Requires Aurora PostgreSQL 16.3+ / 15.7+ / 14.12+ / 13.15+
#                           Default version: 16.6 (stable in all commercial regions)
# ==============================================================================

# ------------------------------------------------------------------------------
# DB SUBNET GROUP  —  private subnets from vpc.tf (2 AZs, already deployed)
# RDS needs subnets in >= 2 AZs, which the existing setup already provides.
# ------------------------------------------------------------------------------
resource "aws_db_subnet_group" "aurora" {
  count = var.aurora_enabled ? 1 : 0

  name        = "${var.cluster_name}-aurora-subnets"
  description = "Private subnets for Aurora Serverless v2 (PostgreSQL)"
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-subnets"
  })
}

# ------------------------------------------------------------------------------
# AURORA SECURITY GROUP
# No ingress inline — follows the same pattern used in vpc.tf for EKS SGs.
# The actual ingress rule is a separate aws_security_group_rule resource below.
# ------------------------------------------------------------------------------
resource "aws_security_group" "aurora" {
  count = var.aurora_enabled ? 1 : 0

  name        = "${var.cluster_name}-aurora-sg"
  description = "Aurora Serverless v2 (PostgreSQL) — ingress only from EKS node SG"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-sg"
  })
}

# Allow PostgreSQL (5432) from the EKS node SG → Aurora.
# Every pod running on any node inherits the node SG for outbound,
# so this single rule covers all pods without any extra config.
resource "aws_security_group_rule" "nodes_to_aurora" {
  count = var.aurora_enabled ? 1 : 0

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora[0].id
  source_security_group_id = aws_security_group.node.id
  description              = "PostgreSQL from EKS node SG (all pods on cluster nodes)"
}

# ------------------------------------------------------------------------------
# CLUSTER PARAMETER GROUP
# Family must match the major version:
#   aurora-postgresql16  →  engine_version 16.x
#   aurora-postgresql17  →  engine_version 17.x
# Controlled by var.aurora_pg_family so you can bump it without editing this file.
# ------------------------------------------------------------------------------
resource "aws_rds_cluster_parameter_group" "aurora" {
  count = var.aurora_enabled ? 1 : 0

  name        = "${var.cluster_name}-aurora-cluster-pg"
  family      = var.aurora_pg_family
  description = "Cluster params for ${var.cluster_name} Aurora Serverless v2 (PostgreSQL)"

  # Reject all non-SSL/TLS connections at the cluster level.
  # In PostgreSQL 17+ the engine already defaults to 1; we set it explicitly
  # here so the config is visible in Terraform regardless of engine version.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  # Log queries slower than N ms to CloudWatch. 1000 = 1 second.
  # Set to -1 to disable slow query logging.
  parameter {
    name         = "log_min_duration_statement"
    value        = var.aurora_log_min_duration_ms
    apply_method = "immediate"
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-cluster-pg"
  })
}

# ------------------------------------------------------------------------------
# AURORA CLUSTER  —  Serverless v2, PostgreSQL-compatible
# ------------------------------------------------------------------------------
resource "aws_rds_cluster" "aurora" {
  count = var.aurora_enabled ? 1 : 0

  cluster_identifier = "${var.cluster_name}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"     # always "provisioned" for Serverless v2
  engine_version     = var.aurora_engine_version
  database_name      = var.aurora_database_name
  master_username    = var.aurora_master_username
  port               = 5432

  # AWS manages and rotates the master password in Secrets Manager.
  # No password ever appears in tfstate, plan output, or tfvars.
  manage_master_user_password = true

  # Required to enable IAM DB token authentication.
  # Without this, the engine refuses token-based logins even if the IAM
  # policy is correct and the DB user has the rds_iam role granted.
  iam_database_authentication_enabled = true

  db_subnet_group_name            = aws_db_subnet_group.aurora[0].name
  vpc_security_group_ids          = [aws_security_group.aurora[0].id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora[0].name
  storage_encrypted               = true

  backup_retention_period = var.aurora_backup_retention_days
  preferred_backup_window = "03:00-04:00"   # UTC (~8:30–9:30 AM IST)

  # Serverless v2 capacity range.
  # min_capacity = 0  →  enables auto-pause (scale-to-zero).
  # seconds_until_auto_pause is only valid when min_capacity = 0.
  serverlessv2_scaling_configuration {
    min_capacity             = var.aurora_min_capacity
    max_capacity             = var.aurora_max_capacity
    seconds_until_auto_pause = var.aurora_min_capacity == 0 ? var.aurora_seconds_until_auto_pause : null
  }

  # "postgresql" captures connections, auth events, and slow queries (via log_min_duration_statement).
  # "upgrade" captures major version upgrade progress.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection       = var.aurora_deletion_protection
  skip_final_snapshot       = var.aurora_skip_final_snapshot
  final_snapshot_identifier = (
    var.aurora_skip_final_snapshot
    ? null
    : "${var.cluster_name}-aurora-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  )

  lifecycle {
    # timestamp() would show as a diff on every plan — suppress after first apply.
    ignore_changes = [final_snapshot_identifier]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora"
  })
}

# ------------------------------------------------------------------------------
# AURORA WRITER INSTANCE
# instance_class = "db.serverless" is the only valid value for Serverless v2.
# Actual ACU capacity is controlled by serverlessv2_scaling_configuration above.
# ------------------------------------------------------------------------------
resource "aws_rds_cluster_instance" "aurora_writer" {
  count = var.aurora_enabled ? 1 : 0

  identifier         = "${var.cluster_name}-aurora-writer"
  cluster_identifier = aws_rds_cluster.aurora[0].id
  engine             = aws_rds_cluster.aurora[0].engine
  engine_version     = aws_rds_cluster.aurora[0].engine_version
  instance_class     = "db.serverless"

  db_subnet_group_name = aws_db_subnet_group.aurora[0].name
  publicly_accessible  = false   # private subnet, no public IP

  performance_insights_enabled = false   # flip to true in prod

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-aurora-writer"
  })
}
