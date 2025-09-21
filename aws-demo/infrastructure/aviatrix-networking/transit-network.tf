# Aviatrix-style Transit Network Architecture for Zero Trust
# Multi-cloud, multi-region connectivity with security domains

# Transit Network Configuration
resource "aws_ec2_transit_gateway" "main" {
  description                     = "Zero Trust Transit Gateway"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support               = "enable"
  multicast_support              = "disable"

  tags = {
    Name = "${var.cluster_name}-transit-gw"
    Type = "zero-trust-networking"
  }
}

# Security Domains as Route Tables
resource "aws_ec2_transit_gateway_route_table" "security_domains" {
  for_each           = var.security_domains
  transit_gateway_id = aws_ec2_transit_gateway.main.id

  tags = {
    Name           = "${var.cluster_name}-${each.key}-domain"
    SecurityDomain = each.key
    Description    = each.value.description
  }
}

# VPC Attachments to Security Domains
resource "aws_ec2_transit_gateway_vpc_attachment" "main" {
  subnet_ids         = module.vpc.private_subnets
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id            = module.vpc.vpc_id
  dns_support       = "enable"

  tags = {
    Name           = "${var.cluster_name}-vpc-attachment"
    SecurityDomain = "production"
  }
}

# Production Security Domain Association
resource "aws_ec2_transit_gateway_route_table_association" "production" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.main.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.security_domains["production"].id
}

# Cross-Region Peering for Multi-Region Zero Trust
resource "aws_ec2_transit_gateway_peering_attachment" "cross_region" {
  count                   = var.enable_aviatrix_connectivity ? 1 : 0
  peer_region            = "us-east-1"
  peer_transit_gateway_id = aws_ec2_transit_gateway.secondary[0].id
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  tags = {
    Name = "${var.cluster_name}-cross-region-peering"
    Type = "zero-trust-cross-region"
  }
}

# Secondary Region Transit Gateway
resource "aws_ec2_transit_gateway" "secondary" {
  count                           = var.enable_aviatrix_connectivity ? 1 : 0
  provider                        = aws.us_east_1
  description                     = "Zero Trust Transit Gateway - Secondary Region"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support               = "enable"

  tags = {
    Name = "${var.cluster_name}-transit-gw-secondary"
    Type = "zero-trust-networking"
  }
}

# Network Firewall for Zero Trust Enforcement
resource "aws_networkfirewall_firewall_policy" "zero_trust" {
  name = "${var.cluster_name}-zero-trust-policy"

  firewall_policy {
    # Default deny all
    stateless_default_actions          = ["aws:drop"]
    stateless_fragment_default_actions = ["aws:drop"]

    # Stateless rules for initial filtering
    stateless_rule_group_reference {
      priority     = 1
      resource_arn = aws_networkfirewall_rule_group.deny_all.arn
    }

    # Stateful rules for application-aware filtering
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.allow_https.arn
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.allow_internal.arn
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.block_malicious.arn
    }
  }

  tags = {
    Name = "${var.cluster_name}-zero-trust-policy"
  }
}

# Deny All Stateless Rule Group (Default Deny)
resource "aws_networkfirewall_rule_group" "deny_all" {
  capacity = 100
  name     = "${var.cluster_name}-deny-all"
  type     = "STATELESS"

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        stateless_rule {
          priority = 1
          rule_definition {
            actions = ["aws:drop"]
            match_attributes {
              source {
                address_definition = "0.0.0.0/0"
              }
              destination {
                address_definition = "0.0.0.0/0"
              }
            }
          }
        }
      }
    }
  }

  tags = {
    Name = "${var.cluster_name}-deny-all"
  }
}

# Allow HTTPS Stateful Rule Group
resource "aws_networkfirewall_rule_group" "allow_https" {
  capacity = 100
  name     = "${var.cluster_name}-allow-https"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_string = <<EOF
pass tcp any any -> any 443 (msg:"Allow HTTPS"; sid:1; rev:1;)
pass tcp any 443 -> any any (msg:"Allow HTTPS response"; sid:2; rev:1;)
pass tcp any any -> any 80 (msg:"Allow HTTP for redirect"; sid:3; rev:1;)
EOF
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name = "${var.cluster_name}-allow-https"
  }
}

# Allow Internal Communication Rule Group
resource "aws_networkfirewall_rule_group" "allow_internal" {
  capacity = 100
  name     = "${var.cluster_name}-allow-internal"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_string = <<EOF
pass tcp ${var.vpc_cidr} any -> ${var.vpc_cidr} any (msg:"Allow internal VPC communication"; sid:10; rev:1;)
pass udp ${var.vpc_cidr} any -> ${var.vpc_cidr} any (msg:"Allow internal VPC UDP"; sid:11; rev:1;)
pass icmp ${var.vpc_cidr} any -> ${var.vpc_cidr} any (msg:"Allow internal ICMP"; sid:12; rev:1;)
pass tcp ${var.vpc_cidr} any -> ${var.vpc_cidr} 53 (msg:"Allow DNS TCP"; sid:13; rev:1;)
pass udp ${var.vpc_cidr} any -> ${var.vpc_cidr} 53 (msg:"Allow DNS UDP"; sid:14; rev:1;)
pass tcp ${var.vpc_cidr} any -> ${var.vpc_cidr} 6443 (msg:"Allow Kubernetes API"; sid:15; rev:1;)
pass tcp ${var.vpc_cidr} any -> ${var.vpc_cidr} 10250 (msg:"Allow Kubelet"; sid:16; rev:1;)
pass tcp ${var.vpc_cidr} any -> ${var.vpc_cidr} 15010:15012 (msg:"Allow Istio control plane"; sid:17; rev:1;)
EOF
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name = "${var.cluster_name}-allow-internal"
  }
}

# Block Malicious Traffic Rule Group
resource "aws_networkfirewall_rule_group" "block_malicious" {
  capacity = 100
  name     = "${var.cluster_name}-block-malicious"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_string = <<EOF
drop tcp any any -> any any (msg:"Block known malicious IPs"; content:"malicious"; sid:100; rev:1;)
drop tcp any any -> any any (msg:"Block SQL injection attempts"; content:"union select"; nocase; sid:101; rev:1;)
drop tcp any any -> any any (msg:"Block XSS attempts"; content:"<script>"; nocase; sid:102; rev:1;)
drop tcp any any -> any any (msg:"Block directory traversal"; content:"../"; sid:103; rev:1;)
drop tcp any any -> any 22 (msg:"Block SSH from external"; sid:104; rev:1;)
drop tcp any any -> any 3389 (msg:"Block RDP"; sid:105; rev:1;)
EOF
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name = "${var.cluster_name}-block-malicious"
  }
}

# Network Firewall
resource "aws_networkfirewall_firewall" "main" {
  name                = "${var.cluster_name}-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.zero_trust.arn
  vpc_id             = module.vpc.vpc_id

  dynamic "subnet_mapping" {
    for_each = module.vpc.private_subnets
    content {
      subnet_id = subnet_mapping.value
    }
  }

  tags = {
    Name = "${var.cluster_name}-firewall"
  }
}

# VPN Gateway for Site-to-Site Connectivity
resource "aws_vpn_gateway" "main" {
  count  = var.enable_aviatrix_connectivity ? 1 : 0
  vpc_id = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-vpn-gateway"
  }
}

# Customer Gateway for On-Premises Connectivity
resource "aws_customer_gateway" "main" {
  count      = var.enable_aviatrix_connectivity ? 1 : 0
  bgp_asn    = 65000
  ip_address = "203.0.113.1"  # Replace with actual public IP
  type       = "ipsec.1"

  tags = {
    Name = "${var.cluster_name}-customer-gateway"
  }
}

# Site-to-Site VPN Connection
resource "aws_vpn_connection" "main" {
  count               = var.enable_aviatrix_connectivity ? 1 : 0
  vpn_gateway_id      = aws_vpn_gateway.main[0].id
  customer_gateway_id = aws_customer_gateway.main[0].id
  type                = "ipsec.1"
  static_routes_only  = true

  tags = {
    Name = "${var.cluster_name}-vpn-connection"
  }
}

# VPN Connection Route for On-Premises Network
resource "aws_vpn_connection_route" "office" {
  count                  = var.enable_aviatrix_connectivity ? 1 : 0
  vpn_connection_id      = aws_vpn_connection.main[0].id
  destination_cidr_block = "192.168.0.0/16"  # On-premises network
}

# Direct Connect Gateway for High-Bandwidth Connectivity
resource "aws_dx_gateway" "main" {
  count           = var.enable_aviatrix_connectivity ? 1 : 0
  name            = "${var.cluster_name}-dx-gateway"
  amazon_side_asn = 64512

  tags = {
    Name = "${var.cluster_name}-dx-gateway"
  }
}

# Transit Gateway Direct Connect Gateway Association
resource "aws_dx_gateway_association" "main" {
  count                  = var.enable_aviatrix_connectivity ? 1 : 0
  dx_gateway_id          = aws_dx_gateway.main[0].id
  associated_gateway_id  = aws_ec2_transit_gateway.main.id
  allowed_prefixes       = [var.vpc_cidr]
}

# Global Accelerator for Performance and DDoS Protection
resource "aws_globalaccelerator_accelerator" "main" {
  count              = var.enable_aviatrix_connectivity ? 1 : 0
  name               = "${var.cluster_name}-accelerator"
  ip_address_type    = "IPV4"
  enabled            = true
  attributes {
    flow_logs_enabled   = true
    flow_logs_s3_bucket = aws_s3_bucket.alb_logs.bucket
    flow_logs_s3_prefix = "global-accelerator-logs/"
  }

  tags = {
    Name = "${var.cluster_name}-accelerator"
  }
}

# Global Accelerator Listener
resource "aws_globalaccelerator_listener" "main" {
  count           = var.enable_aviatrix_connectivity ? 1 : 0
  accelerator_arn = aws_globalaccelerator_accelerator.main[0].id
  client_affinity = "SOURCE_IP"
  protocol        = "TCP"

  port_range {
    from = 443
    to   = 443
  }
}

# Global Accelerator Endpoint Group
resource "aws_globalaccelerator_endpoint_group" "main" {
  count                 = var.enable_aviatrix_connectivity ? 1 : 0
  listener_arn          = aws_globalaccelerator_listener.main[0].id
  endpoint_group_region = var.aws_region

  endpoint_configuration {
    endpoint_id = aws_lb.main.arn
    weight      = 100
  }

  health_check_grace_period_seconds = 30
  health_check_interval_seconds     = 30
  health_check_path                 = "/health"
  health_check_protocol             = "HTTPS"
  health_check_port                 = 443
  threshold_count                   = 3
  traffic_dial_percentage           = 100
}

# CloudFront Distribution for Edge Security
resource "aws_cloudfront_distribution" "main" {
  count = var.enable_aviatrix_connectivity ? 1 : 0

  origin {
    domain_name = aws_lb.main.dns_name
    origin_id   = "ALB-${var.cluster_name}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Zero Trust CloudFront Distribution"
  default_root_object = "index.html"

  aliases = ["gateway.${var.domain_name}"]

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "ALB-${var.cluster_name}"

    forwarded_values {
      query_string = true
      headers      = ["Host", "Authorization", "CloudFront-Forwarded-Proto"]

      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
  }

  # WAF Association
  web_acl_id = aws_wafv2_web_acl.main.arn

  # Security Headers
  response_headers_policy_id = aws_cloudfront_response_headers_policy.security_headers[0].id

  # Geographic restrictions
  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE", "FR", "AU", "JP"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.main[0].arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.cluster_name}-cloudfront"
  }
}

# CloudFront Security Headers Policy
resource "aws_cloudfront_response_headers_policy" "security_headers" {
  count = var.enable_aviatrix_connectivity ? 1 : 0
  name  = "${var.cluster_name}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

# ACM Certificate for HTTPS
resource "aws_acm_certificate" "main" {
  count                     = var.enable_aviatrix_connectivity ? 1 : 0
  domain_name               = "gateway.${var.domain_name}"
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.cluster_name}-certificate"
  }
}

# Route 53 Record for Certificate Validation
resource "aws_route53_record" "cert_validation" {
  count           = var.enable_aviatrix_connectivity ? 1 : 0
  allow_overwrite = true
  name            = tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_name
  records         = [tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_value]
  ttl             = 60
  type            = tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_type
  zone_id         = aws_route53_zone.main.zone_id
}

# Certificate Validation
resource "aws_acm_certificate_validation" "main" {
  count                   = var.enable_aviatrix_connectivity ? 1 : 0
  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [aws_route53_record.cert_validation[0].fqdn]
}

# Provider for Secondary Region
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "zuul-zero-trust-demo"
      Environment = var.environment
      Owner       = "devops-team"
      CreatedBy   = "terraform"
      Security    = "zero-trust"
      Region      = "secondary"
    }
  }
}