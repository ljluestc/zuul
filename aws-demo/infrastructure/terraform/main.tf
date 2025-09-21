# Zero Trust AWS EKS Cluster Infrastructure
# Based on AWS Solutions Architect Associate Best Practices

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
  }

  backend "s3" {
    bucket         = "zuul-zero-trust-terraform-state"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "zuul-terraform-locks"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "zuul-zero-trust-demo"
      Environment = var.environment
      Owner       = "devops-team"
      CreatedBy   = "terraform"
      Security    = "zero-trust"
    }
  }
}

# Data sources
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# VPC Configuration for Zero Trust Network
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  # Private subnets for EKS nodes (zero trust principle)
  private_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 1),
    cidrsubnet(var.vpc_cidr, 8, 2),
    cidrsubnet(var.vpc_cidr, 8, 3),
  ]

  # Public subnets for load balancers only
  public_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 101),
    cidrsubnet(var.vpc_cidr, 8, 102),
    cidrsubnet(var.vpc_cidr, 8, 103),
  ]

  # Database subnets for RDS (isolated)
  database_subnets = [
    cidrsubnet(var.vpc_cidr, 8, 201),
    cidrsubnet(var.vpc_cidr, 8, 202),
    cidrsubnet(var.vpc_cidr, 8, 203),
  ]

  # Enable DNS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # NAT Gateway for outbound traffic from private subnets
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  # VPC Flow Logs for security monitoring
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_traffic_type                = "ALL"

  # Network ACLs for additional security
  manage_default_network_acl = true
  default_network_acl_tags   = { Name = "${var.cluster_name}-default-nacl" }

  # Security Groups
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${var.cluster_name}-default-sg" }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Security Groups for Zero Trust
resource "aws_security_group" "eks_cluster_sg" {
  name_prefix = "${var.cluster_name}-cluster-sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_security_group" "eks_node_sg" {
  name_prefix = "${var.cluster_name}-node-sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Cluster communication"
    from_port   = 1025
    to_port     = 65535
    protocol    = "tcp"
    security_groups = [aws_security_group.eks_cluster_sg.id]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [aws_security_group.eks_cluster_sg.id]
  }

  ingress {
    description = "Node to node communication"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-node-sg"
  }
}

# KMS Key for EKS encryption
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${var.cluster_name}-eks-encryption-key"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks-encryption-key"
  target_key_id = aws_kms_key.eks.key_id
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  cluster_endpoint_private_access = true

  # Restrict public access to specific CIDR blocks
  cluster_endpoint_public_access_cidrs = var.allowed_cidr_blocks

  # Enable encryption
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  # Security enhancements
  cluster_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    # General purpose nodes
    general = {
      name = "general"

      instance_types = ["t3.large"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 10
      desired_size = 3

      # Ensure nodes are placed in private subnets
      subnet_ids = module.vpc.private_subnets

      # Security configurations
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            encrypted             = true
            kms_key_id           = aws_kms_key.eks.arn
            delete_on_termination = true
          }
        }
      }

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
        instance_metadata_tags      = "enabled"
      }

      # Additional security group rules
      security_group_rules = {
        ingress_cluster_443 = {
          description                = "Cluster API to node groups"
          protocol                   = "tcp"
          from_port                  = 443
          to_port                    = 443
          type                       = "ingress"
          source_cluster_security_group = true
        }
        ingress_cluster_kubelet = {
          description                = "Cluster API to node kubelets"
          protocol                   = "tcp"
          from_port                  = 10250
          to_port                    = 10250
          type                       = "ingress"
          source_cluster_security_group = true
        }
      }

      labels = {
        Environment = var.environment
        WorkerType  = "general"
      }

      taints = []

      tags = {
        ExtraTag = "general-nodes"
      }
    }

    # Security focused nodes for sensitive workloads
    security = {
      name = "security"

      instance_types = ["c5.xlarge"]
      capacity_type  = "ON_DEMAND"

      min_size     = 1
      max_size     = 5
      desired_size = 2

      subnet_ids = module.vpc.private_subnets

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 150
            encrypted             = true
            kms_key_id           = aws_kms_key.eks.arn
            delete_on_termination = true
          }
        }
      }

      labels = {
        Environment     = var.environment
        WorkerType      = "security"
        SecurityLevel   = "high"
        TrustedCompute  = "true"
      }

      taints = [
        {
          key    = "security"
          value  = "required"
          effect = "NO_SCHEDULE"
        }
      ]

      tags = {
        ExtraTag = "security-nodes"
      }
    }
  }

  # Fargate profiles for serverless pods
  fargate_profiles = {
    security_scanning = {
      name = "security-scanning"
      selectors = [
        {
          namespace = "security-scanning"
        }
      ]

      subnet_ids = module.vpc.private_subnets

      tags = {
        WorkloadType = "security-scanning"
      }
    }
  }

  # aws-auth configmap
  manage_aws_auth_configmap = true

  aws_auth_roles = [
    {
      rolearn  = aws_iam_role.eks_admin_role.arn
      username = "eks-admin"
      groups   = ["system:masters"]
    },
  ]

  aws_auth_users = var.eks_admin_users

  # OIDC Identity provider
  cluster_identity_providers = {
    github = {
      client_id = var.github_oidc_client_id
    }
  }

  tags = {
    Environment = var.environment
  }
}

# IAM Role for EKS Administrators
resource "aws_iam_role" "eks_admin_role" {
  name = "${var.cluster_name}-eks-admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-eks-admin-role"
  }
}

# CloudWatch Log Groups for container insights
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 14
  kms_key_id       = aws_kms_key.eks.arn

  tags = {
    Name = "${var.cluster_name}-cluster-logs"
  }
}

# ECR Repository for container images
resource "aws_ecr_repository" "zuul_gateway" {
  name                 = "zuul-gateway"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key        = aws_kms_key.eks.arn
  }

  tags = {
    Name = "zuul-gateway"
  }
}

# ECR Lifecycle Policy
resource "aws_ecr_lifecycle_policy" "zuul_gateway" {
  repository = aws_ecr_repository.zuul_gateway.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Route 53 Hosted Zone for DNS
resource "aws_route53_zone" "main" {
  name = var.domain_name

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  tags = {
    Name = "${var.cluster_name}-dns-zone"
  }
}

# Application Load Balancer for ingress
resource "aws_lb" "main" {
  name               = "${var.cluster_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets           = module.vpc.public_subnets

  enable_deletion_protection = false
  enable_http2              = true
  enable_waf_fail_open      = false

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb-access-logs"
    enabled = true
  }

  tags = {
    Name = "${var.cluster_name}-alb"
  }
}

# Security Group for ALB
resource "aws_security_group" "alb_sg" {
  name_prefix = "${var.cluster_name}-alb-sg"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-alb-sg"
  }
}

# S3 Bucket for ALB Access Logs
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.cluster_name}-alb-logs-${random_string.bucket_suffix.result}"
  force_destroy = true

  tags = {
    Name = "${var.cluster_name}-alb-logs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.eks.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# WAF for additional security
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.cluster_name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputsRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Name = "${var.cluster_name}-waf"
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "ZuulWAF"
    sampled_requests_enabled   = true
  }
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}