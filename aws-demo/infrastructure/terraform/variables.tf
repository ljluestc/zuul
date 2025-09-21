# Variables for Zero Trust EKS Demo Infrastructure

variable "aws_region" {
  description = "AWS region for infrastructure"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "demo"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "zuul-zero-trust-demo"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.27"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access EKS API"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Restrict this in production
}

variable "domain_name" {
  description = "Domain name for the demo"
  type        = string
  default     = "zuul-demo.local"
}

variable "github_oidc_client_id" {
  description = "GitHub OIDC client ID for authentication"
  type        = string
  default     = ""
}

variable "external_id" {
  description = "External ID for role assumption"
  type        = string
  default     = "zuul-demo-external-id"
}

variable "eks_admin_users" {
  description = "List of IAM users that should have admin access to EKS"
  type = list(object({
    userarn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

# Aviatrix-style multi-cloud connectivity variables
variable "enable_aviatrix_connectivity" {
  description = "Enable Aviatrix-style multi-cloud connectivity"
  type        = bool
  default     = true
}

variable "transit_gateways" {
  description = "Configuration for transit gateways in different regions"
  type = map(object({
    region = string
    cidr   = string
    ha_enabled = bool
  }))
  default = {
    primary = {
      region = "us-west-2"
      cidr   = "10.1.0.0/16"
      ha_enabled = true
    }
    secondary = {
      region = "us-east-1"
      cidr   = "10.2.0.0/16"
      ha_enabled = true
    }
  }
}

variable "security_domains" {
  description = "Security domains for network segmentation"
  type = map(object({
    description = string
    firewall_policies = list(string)
    connected_domains = list(string)
  }))
  default = {
    production = {
      description = "Production workloads"
      firewall_policies = ["deny-all", "allow-https", "allow-monitoring"]
      connected_domains = ["shared-services"]
    }
    development = {
      description = "Development workloads"
      firewall_policies = ["allow-internal", "allow-https"]
      connected_domains = ["shared-services"]
    }
    shared-services = {
      description = "Shared services like DNS, monitoring"
      firewall_policies = ["allow-internal"]
      connected_domains = ["production", "development"]
    }
    dmz = {
      description = "DMZ for external access"
      firewall_policies = ["allow-https-in", "deny-internal"]
      connected_domains = []
    }
  }
}

# Zero Trust Security Configuration
variable "zero_trust_config" {
  description = "Zero trust security configuration"
  type = object({
    enable_network_segmentation = bool
    enable_identity_verification = bool
    enable_device_compliance = bool
    enable_continuous_monitoring = bool
    default_deny_policy = bool
    encryption_in_transit = bool
    encryption_at_rest = bool
  })
  default = {
    enable_network_segmentation = true
    enable_identity_verification = true
    enable_device_compliance = true
    enable_continuous_monitoring = true
    default_deny_policy = true
    encryption_in_transit = true
    encryption_at_rest = true
  }
}

# Container Security Configuration
variable "container_security" {
  description = "Container security configuration"
  type = object({
    enable_image_scanning = bool
    enable_runtime_protection = bool
    enable_network_policies = bool
    enable_pod_security_standards = bool
    vulnerability_threshold = string
    compliance_frameworks = list(string)
  })
  default = {
    enable_image_scanning = true
    enable_runtime_protection = true
    enable_network_policies = true
    enable_pod_security_standards = true
    vulnerability_threshold = "medium"
    compliance_frameworks = ["nist", "pci-dss", "soc2"]
  }
}

# Monitoring and Observability
variable "monitoring_config" {
  description = "Monitoring and observability configuration"
  type = object({
    enable_container_insights = bool
    enable_service_mesh_monitoring = bool
    enable_security_monitoring = bool
    enable_cost_monitoring = bool
    log_retention_days = number
    metrics_retention_days = number
  })
  default = {
    enable_container_insights = true
    enable_service_mesh_monitoring = true
    enable_security_monitoring = true
    enable_cost_monitoring = true
    log_retention_days = 14
    metrics_retention_days = 30
  }
}

# Demo Application Configuration
variable "demo_apps" {
  description = "Demo applications to deploy"
  type = map(object({
    name = string
    namespace = string
    replicas = number
    security_level = string
    external_access = bool
    image_repository = string
  }))
  default = {
    zuul_gateway = {
      name = "zuul-gateway"
      namespace = "zuul-security"
      replicas = 3
      security_level = "high"
      external_access = true
      image_repository = "zuul-gateway"
    }
    backend_api = {
      name = "backend-api"
      namespace = "backend"
      replicas = 2
      security_level = "medium"
      external_access = false
      image_repository = "backend-api"
    }
    database = {
      name = "postgres"
      namespace = "data"
      replicas = 1
      security_level = "critical"
      external_access = false
      image_repository = "postgres"
    }
  }
}