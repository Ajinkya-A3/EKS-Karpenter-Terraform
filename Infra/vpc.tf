# =========================================
# VPC
# =========================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true # required for interface endpoint DNS resolution

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-vpc"
  })
}

# =========================================
# INTERNET GATEWAY
# =========================================
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-igw"
  })
}

# =========================================
# AVAILABILITY ZONES
# =========================================
data "aws_availability_zones" "available" {}

# =========================================
# PUBLIC SUBNETS
# CIDRs: 10.0.0.0/24, 10.0.1.0/24, ...
# =========================================
resource "aws_subnet" "public" {
  count = var.public_subnet_count

  vpc_id = aws_vpc.main.id

  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)

  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-${count.index}"

    # Required for internet-facing ALBs
    "kubernetes.io/role/elb" = "1"

    # Required for EKS
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# PRIVATE SUBNETS
# CIDRs start at offset 10 to avoid collision with public subnets:
# 10.0.10.0/24, 10.0.11.0/24, ...
# =========================================
resource "aws_subnet" "private" {
  count = var.public_subnet_count # one private subnet per AZ, same count as public

  vpc_id = aws_vpc.main.id

  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index + 10)

  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-private-${count.index}"

    # Required for internal ALBs
    "kubernetes.io/role/internal-elb" = "1"

    # Required for EKS
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"

    # Required for Karpenter subnet discovery
    "karpenter.sh/discovery" = var.cluster_name
  })
}

# =========================================
# EIP FOR NAT GATEWAY (single, in AZ-0)
# =========================================
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat-eip"
  })

  depends_on = [aws_internet_gateway.igw]
}

# =========================================
# NAT GATEWAY (single, placed in public subnet 0)
# With all VPC endpoints in place, the NAT only handles traffic
# to truly external destinations (e.g. GitHub, DockerHub, apt repos).
# ECR, S3, STS, EC2, SQS, SSM, EKS all bypass it entirely.
# =========================================
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # must live in a public subnet 

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-nat"
  })

  depends_on = [aws_internet_gateway.igw]
}

# =========================================
# PUBLIC ROUTE TABLE
# =========================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-public-rt"
  })
}

# =========================================
# INTERNET ROUTE
# =========================================
resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# =========================================
# ROUTE TABLE ASSOCIATION
# =========================================
resource "aws_route_table_association" "public_assoc" {
  count = var.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =========================================
# PRIVATE ROUTE TABLE (single, shared by all private subnets)
# Routes outbound traffic through the NAT Gateway.
# =========================================
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-private-rt"
  })
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  count = var.public_subnet_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# =========================================
# EKS CLUSTER SECURITY GROUP
# =========================================
resource "aws_security_group" "eks_cluster" {
  name   = "${var.cluster_name}-eks-cluster-sg"
  vpc_id = aws_vpc.main.id

  # ← NO ingress blocks here at all
  # ← KEEP egress inline — egress-only rules don't have this conflict

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # This is critical — tells Terraform "don't manage ingress inline"
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = merge(var.tags, {
    Name                                        = "${var.cluster_name}-eks-cluster-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# =========================================
# NODE SECURITY GROUP
# =========================================
resource "aws_security_group" "node" {
  name   = "${var.cluster_name}-node-sg"
  vpc_id = aws_vpc.main.id

  # ← NO ingress blocks here

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
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  })
}

# =========================================
# ALL INGRESS RULES AS SEPARATE RESOURCES
# =========================================

# Cluster → Node (all traffic)
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.node.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Cluster to node all traffic"
}

# Node → Cluster (all traffic)
resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.node.id
  description              = "Node to cluster all traffic"
}

# Node → Node (self)
resource "aws_security_group_rule" "node_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.node.id
  self              = true
  description       = "Node to node all traffic"
}

# Cluster API access (kubectl)
resource "aws_security_group_rule" "cluster_api_access" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.eks_cluster.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow HTTPS kubectl / API"
}

# ALB → Node ports
resource "aws_security_group_rule" "alb_to_node" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  security_group_id = aws_security_group.node.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "Allow ALB to reach node ports"
}