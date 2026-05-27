
# =========================================
# SECURITY GROUP FOR INTERFACE ENDPOINTS
# Shared by all interface endpoints.
# Created only when at least one interface endpoint is enabled.
# =========================================
locals {
  any_interface_endpoint_enabled = (
    var.enable_endpoint_ecr_api ||
    var.enable_endpoint_ecr_dkr ||
    var.enable_endpoint_ec2     ||
    var.enable_endpoint_sts     ||
    var.enable_endpoint_sqs     ||
    var.enable_endpoint_eks     ||
    var.enable_endpoint_ssm
  )
}

resource "aws_security_group" "vpc_endpoints" {
  count = local.any_interface_endpoint_enabled ? 1 : 0

  name        = "${var.cluster_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from within VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc-endpoints-sg"
  })
}

# =========================================
# GATEWAY ENDPOINTS — always FREE.
# No hourly cost, no data charge, no SG needed.
# Traffic to these services never touches NAT.
# =========================================

# S3 Gateway Endpoint
# ECR stores image layers in S3. This single endpoint eliminates
# the largest source of NAT data charges on an EKS cluster.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id
  ]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-s3-endpoint"
  })
}

# DynamoDB Gateway Endpoint — free, no reason to toggle.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id
  ]

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-dynamodb-endpoint"
  })
}

# =========================================
# INTERFACE ENDPOINTS
# Each costs ~$7-8/month (2 AZs x $0.01/hr x 720hrs).
# Toggle each independently via variables in variables.tf.
# =========================================

# ECR API — image manifest auth
# Required if you pull images from ECR.
resource "aws_vpc_endpoint" "ecr_api" {
  count = var.enable_endpoint_ecr_api ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-api-endpoint"
  })
}

# ECR DKR — actual image layer pulls (docker registry protocol).
# Works with the S3 endpoint: manifest via ecr.dkr, layers from S3.
resource "aws_vpc_endpoint" "ecr_dkr" {
  count = var.enable_endpoint_ecr_dkr ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ecr-dkr-endpoint"
  })
}

# EC2 — Karpenter makes heavy EC2 API calls:
# RunInstances, DescribeInstances, CreateFleet, TerminateInstances, etc.
resource "aws_vpc_endpoint" "ec2" {
  count = var.enable_endpoint_ec2 ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ec2-endpoint"
  })
}

# STS — IRSA token exchange.
# Karpenter controller, ALB controller, and EBS CSI driver all call
# sts:AssumeRoleWithWebIdentity on every pod startup and token refresh.
resource "aws_vpc_endpoint" "sts" {
  count = var.enable_endpoint_sts ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sts-endpoint"
  })
}

# SQS — Karpenter polls the interruption queue continuously.
# Only needed if Karpenter Spot interruption handling is active.
# If you disable Spot or remove the interruption queue, set to false.
resource "aws_vpc_endpoint" "sqs" {
  count = var.enable_endpoint_sqs ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-sqs-endpoint"
  })
}

# EKS — node bootstrap and kubelet API server communication.
# Optional: cluster has public endpoint enabled so kubelet can fall back.
# Enable to avoid kubelet traffic going through NAT in a fully private setup.
resource "aws_vpc_endpoint" "eks" {
  count = var.enable_endpoint_eks ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.eks"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-eks-endpoint"
  })
}

# =========================================
# SSM SESSION MANAGER — optional trio
# All three are controlled by a single variable: enable_endpoint_ssm
# Use case: shell access to nodes without SSH or a bastion host.
# NOTE: All three must be on together — enabling only one or two breaks SSM.
# =========================================

resource "aws_vpc_endpoint" "ssm" {
  count = var.enable_endpoint_ssm ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ssm-endpoint"
  })
}

resource "aws_vpc_endpoint" "ssmmessages" {
  count = var.enable_endpoint_ssm ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ssmmessages-endpoint"
  })
}

resource "aws_vpc_endpoint" "ec2messages" {
  count = var.enable_endpoint_ssm ? 1 : 0

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-ec2messages-endpoint"
  })
}
