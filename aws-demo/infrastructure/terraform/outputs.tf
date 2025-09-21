# Outputs for Zero Trust EKS Demo Infrastructure

# Cluster Information
output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster for the OpenID Connect identity provider"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

# VPC Information
output "vpc_id" {
  description = "ID of the VPC where cluster is deployed"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "database_subnets" {
  description = "List of IDs of database subnets"
  value       = module.vpc.database_subnets
}

# Security Information
output "kms_key_id" {
  description = "KMS Key ID for encryption"
  value       = aws_kms_key.eks.id
}

output "kms_key_arn" {
  description = "KMS Key ARN for encryption"
  value       = aws_kms_key.eks.arn
}

# Load Balancer Information
output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the load balancer"
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

# Container Registry Information
output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.zuul_gateway.repository_url
}

output "ecr_registry_id" {
  description = "Registry ID of the ECR repository"
  value       = aws_ecr_repository.zuul_gateway.registry_id
}

# DNS Information
output "route53_zone_id" {
  description = "Route53 zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "route53_name_servers" {
  description = "Route53 name servers"
  value       = aws_route53_zone.main.name_servers
}

# Security Groups
output "eks_cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = aws_security_group.eks_cluster_sg.id
}

output "eks_node_security_group_id" {
  description = "EKS node security group ID"
  value       = aws_security_group.eks_node_sg.id
}

output "alb_security_group_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb_sg.id
}

# WAF Information
output "waf_web_acl_id" {
  description = "WAF Web ACL ID"
  value       = aws_wafv2_web_acl.main.id
}

output "waf_web_acl_arn" {
  description = "WAF Web ACL ARN"
  value       = aws_wafv2_web_acl.main.arn
}

# S3 Bucket Information
output "alb_logs_bucket" {
  description = "S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.bucket
}

# IAM Information
output "eks_admin_role_arn" {
  description = "ARN of EKS admin role"
  value       = aws_iam_role.eks_admin_role.arn
}

# CloudWatch Information
output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for EKS cluster"
  value       = aws_cloudwatch_log_group.eks_cluster.name
}

# kubectl Configuration Command
output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}

# Helm Commands for Security Tools
output "helm_commands" {
  description = "Helm commands to install security tools"
  value = {
    istio = "helm repo add istio https://istio-release.storage.googleapis.com/charts && helm install istio-base istio/base -n istio-system --create-namespace"
    argo_rollouts = "helm repo add argo https://argoproj.github.io/argo-helm && helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace"
    kyverno = "helm repo add kyverno https://kyverno.github.io/kyverno && helm install kyverno kyverno/kyverno -n kyverno --create-namespace"
    falco = "helm repo add falcosecurity https://falcosecurity.github.io/charts && helm install falco falcosecurity/falco -n falco --create-namespace"
    prometheus = "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace"
  }
}

# Security Endpoints
output "security_endpoints" {
  description = "Security-related endpoints and URLs"
  value = {
    grafana_url = "https://grafana.${var.domain_name}"
    prometheus_url = "https://prometheus.${var.domain_name}"
    istio_kiali_url = "https://kiali.${var.domain_name}"
    zuul_gateway_url = "https://gateway.${var.domain_name}"
    argo_rollouts_dashboard = "https://rollouts.${var.domain_name}"
  }
}

# Network Configuration
output "network_configuration" {
  description = "Network configuration details"
  value = {
    vpc_cidr = var.vpc_cidr
    availability_zones = data.aws_availability_zones.available.names
    nat_gateway_ips = module.vpc.nat_public_ips
    vpc_flow_logs_enabled = true
  }
}

# Security Configuration Summary
output "security_configuration" {
  description = "Security configuration summary"
  value = {
    encryption_at_rest = "Enabled (KMS)"
    encryption_in_transit = "Enabled (TLS/mTLS)"
    network_segmentation = "Enabled (Network Policies + Security Groups)"
    vulnerability_scanning = "Enabled (ECR + Trivy/Grype)"
    pod_security_standards = "Restricted"
    waf_protection = "Enabled"
    ddos_protection = "AWS Shield Standard"
    access_logging = "Enabled (ALB + VPC Flow Logs)"
  }
}

# Compliance Information
output "compliance_information" {
  description = "Compliance framework alignment"
  value = {
    frameworks = ["NIST Cybersecurity Framework", "SOC 2", "PCI DSS", "GDPR"]
    controls_implemented = [
      "AC-3: Access Enforcement",
      "AC-4: Information Flow Enforcement",
      "AU-2: Audit Events",
      "CM-2: Baseline Configuration",
      "CP-9: Information System Backup",
      "IA-2: Identification and Authentication",
      "SC-7: Boundary Protection",
      "SC-8: Transmission Confidentiality",
      "SC-28: Protection of Information at Rest",
      "SI-3: Malicious Code Protection",
      "SI-4: Information System Monitoring"
    ]
  }
}

# Cost Optimization Information
output "cost_optimization" {
  description = "Cost optimization features"
  value = {
    spot_instances = "Available for non-critical workloads"
    fargate_enabled = "Yes, for security scanning workloads"
    resource_quotas = "Enabled per namespace"
    horizontal_pod_autoscaling = "Configured"
    cluster_autoscaling = "Enabled"
    reserved_capacity = "Recommended for production"
  }
}

# Disaster Recovery Information
output "disaster_recovery" {
  description = "Disaster recovery configuration"
  value = {
    multi_az_deployment = "Yes"
    backup_strategy = "EBS snapshots + ETCD backups"
    rto_target = "< 1 hour"
    rpo_target = "< 15 minutes"
    cross_region_replication = "Configurable"
  }
}

# Demo URLs and Access Information
output "demo_access_information" {
  description = "Demo access information and URLs"
  value = {
    cluster_name = var.cluster_name
    region = var.aws_region
    domain = var.domain_name
    admin_role = aws_iam_role.eks_admin_role.arn
    kubectl_config = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
    demo_apps = {
      zuul_gateway = "https://gateway.${var.domain_name}"
      monitoring = "https://grafana.${var.domain_name}"
      service_mesh = "https://kiali.${var.domain_name}"
    }
  }
}