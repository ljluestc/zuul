# Zuul Security Infrastructure Deployment

This repository contains a comprehensive security infrastructure setup for deploying Netflix's Zuul API Gateway on Kubernetes with advanced security features including SBOM image scanning, canary deployments, and zero-trust microsegmentation.

## 🔐 Security Features

### Core Security Components
- **SBOM Generation**: Automated Software Bill of Materials using Syft
- **Vulnerability Scanning**: Container and dependency scanning with Grype
- **Image Signing**: Container image signing with Cosign
- **Zero-Trust Architecture**: Istio service mesh with mTLS
- **Network Microsegmentation**: Kubernetes Network Policies + Calico
- **Canary Deployments**: Argo Rollouts with security validation
- **Security Pipeline**: Tekton-based CI/CD with security gates
- **Policy Enforcement**: Kyverno + Gatekeeper admission controllers
- **External Authorization**: Custom authz service with OPA integration

### Security Standards Compliance
- **Pod Security Standards**: Restricted profile enforcement
- **NIST Cybersecurity Framework**: Implementation aligned with NIST guidelines
- **Zero Trust Principles**: Never trust, always verify
- **Defense in Depth**: Multiple security layers
- **Least Privilege Access**: RBAC with minimal permissions

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Internet/Load Balancer                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                 Istio Gateway                               │
│           (TLS Termination, WAF)                           │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                External AuthZ Service                      │
│        (JWT Validation, RBAC, Rate Limiting)              │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│               Zuul Gateway Pods                            │
│     (Canary Deployment with Security Validation)          │
│                                                            │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐      │
│  │   Stable     │ │    Canary    │ │   Security   │      │
│  │   Replicas   │ │   Replicas   │ │   Sidecar    │      │
│  │              │ │              │ │   (Istio)    │      │
│  └──────────────┘ └──────────────┘ └──────────────┘      │
└─────────────────────┬───────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────┐
│                Backend Services                            │
│           (mTLS + Network Policies)                       │
└─────────────────────────────────────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

1. **Kubernetes Cluster** (1.25+)
2. **kubectl** configured
3. **Docker** with registry access
4. **Helm** (3.0+)
5. **Required tools**:
   ```bash
   # Install required CLI tools
   curl -L https://istio.io/downloadIstio | sh -
   curl -L https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64 -o kubectl-argo-rollouts
   ```

### One-Click Deployment

```bash
# Clone the repository
git clone https://github.com/Netflix/zuul.git
cd zuul

# Set your container registry
export REGISTRY="your-registry.com"
export IMAGE_TAG="v1.0.0"

# Deploy the complete security infrastructure
./scripts/deploy-security-infrastructure.sh
```

### Manual Step-by-Step Deployment

#### 1. Setup Namespaces and RBAC
```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac.yaml
```

#### 2. Deploy Security Policies
```bash
# Pod Security Standards
kubectl apply -f k8s/security-policies/pod-security-standards.yaml

# Network Policies for Zero Trust
kubectl apply -f k8s/zero-trust/network-policies.yaml
```

#### 3. Deploy Istio Security Configuration
```bash
# Install Istio (if not already installed)
istioctl install --set values.defaultRevision=default -y

# Apply security policies
kubectl apply -f k8s/zero-trust/istio-security.yaml
```

#### 4. Deploy External Authorization Service
```bash
kubectl apply -f k8s/external-authz/authz-service.yaml
```

#### 5. Setup Security Scanning Infrastructure
```bash
# ConfigMaps and scanning jobs
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/security-scanning/sbom-scanner.yaml
kubectl apply -f k8s/security-scanning/admission-controller.yaml
```

#### 6. Deploy Security Pipeline
```bash
# Tekton pipeline with security gates
kubectl apply -f k8s/security-pipeline/tekton-pipeline.yaml
kubectl apply -f k8s/security-pipeline/triggers.yaml
```

#### 7. Build and Deploy Zuul Gateway
```bash
# Build secure container image
docker build -t ${REGISTRY}/zuul-gateway:${IMAGE_TAG} .

# Sign image (optional but recommended)
cosign sign --yes ${REGISTRY}/zuul-gateway:${IMAGE_TAG}

# Deploy with canary strategy
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/canary-deployment/
```

## 🔍 Security Validation

### Automated Security Checks

The deployment includes automated security validation:

1. **Pre-deployment Scans**:
   - Source code security scanning (Trufflehog)
   - Dependency vulnerability scanning (OWASP)
   - SAST analysis (SonarQube)

2. **Container Security**:
   - SBOM generation (Syft)
   - Vulnerability scanning (Grype)
   - Configuration scanning (Trivy)
   - Image signing (Cosign)

3. **Runtime Security**:
   - Pod Security Standards enforcement
   - Network policy validation
   - mTLS certificate verification
   - Authorization policy testing

### Manual Security Verification

#### Check Security Policies
```bash
# Verify Pod Security Standards
kubectl get pods -n zuul-security -o yaml | grep securityContext

# Check Network Policies
kubectl get networkpolicies -A

# Validate Istio mTLS
istioctl authn tls-check zuul-gateway.zuul-security.svc.cluster.local
```

#### Verify SBOM and Vulnerability Reports
```bash
# Check SBOM generation
kubectl logs -n security-scanning job/sbom-scanner

# View vulnerability scan results
kubectl get configmap vulnerability-reports -n security-scanning -o yaml
```

#### Test Authorization Policies
```bash
# Test without authentication (should fail)
curl -k https://gateway.yourdomain.com/api/users

# Test with valid JWT (should succeed)
curl -k -H "Authorization: Bearer <valid-jwt>" https://gateway.yourdomain.com/api/users
```

## 📊 Monitoring and Observability

### Security Metrics

The deployment includes comprehensive security monitoring:

- **Authentication/Authorization metrics**
- **mTLS certificate expiration**
- **Vulnerability scan results**
- **Network policy violations**
- **Security policy enforcement**

### Dashboards

Access security dashboards at:
- **Grafana**: `https://grafana.yourdomain.com`
- **Prometheus**: `https://prometheus.yourdomain.com`
- **Istio Kiali**: `https://kiali.yourdomain.com`

### Alerting

Security alerts are configured for:
- Critical vulnerabilities detected
- mTLS certificate expiration
- High authentication failure rates
- Network policy violations
- Unauthorized access attempts

## 🔄 Canary Deployment Process

### Automated Canary Strategy

1. **Deploy canary** (10% traffic)
2. **Security validation** (vulnerability scan + policy check)
3. **Progressive rollout** (20% → 50% → 100%)
4. **Automated rollback** on security violations

### Monitoring Canary Deployments

```bash
# Watch rollout progress
kubectl argo rollouts get rollout zuul-gateway-rollout -n zuul-security -w

# Check security analysis results
kubectl get analysisruns -n zuul-security

# Manual rollback if needed
kubectl argo rollouts abort zuul-gateway-rollout -n zuul-security
```

## 🛡️ Zero Trust Implementation

### Network Microsegmentation

- **Default Deny**: All traffic blocked by default
- **Explicit Allow**: Only necessary connections permitted
- **Namespace Isolation**: Strong boundaries between services
- **Pod-to-Pod mTLS**: All service communication encrypted

### Identity and Access Management

- **Service Accounts**: Dedicated SAs with minimal permissions
- **JWT Validation**: Token-based authentication
- **RBAC Enforcement**: Role-based access control
- **External AuthZ**: Custom authorization decisions

### Data Protection

- **Encryption in Transit**: mTLS for all connections
- **Encryption at Rest**: Encrypted storage volumes
- **Secret Management**: Kubernetes secrets with encryption
- **Certificate Rotation**: Automated cert lifecycle

## 🔧 Configuration

### Environment Variables

Key configuration options:

```bash
# Container Registry
export REGISTRY="your-registry.com"

# Image Tag
export IMAGE_TAG="v1.0.0"

# Security Threshold
export SECURITY_THRESHOLD="medium"  # critical, high, medium, low

# JWT Configuration
export JWT_ISSUER="https://accounts.yourdomain.com"
export JWT_AUDIENCE="zuul-gateway"
```

### Security Policies

Edit security policies in:
- `k8s/security-policies/pod-security-standards.yaml`
- `k8s/zero-trust/istio-security.yaml`
- `k8s/external-authz/authz-service.yaml`

## 🚨 Incident Response

### Security Incident Playbook

1. **Immediate Response**:
   ```bash
   # Scale down affected deployment
   kubectl scale deployment zuul-gateway --replicas=0 -n zuul-security

   # Block network traffic
   kubectl apply -f emergency-network-policy.yaml
   ```

2. **Investigation**:
   ```bash
   # Check security logs
   kubectl logs -n zuul-security -l app=zuul-gateway --since=1h

   # Review authorization logs
   kubectl logs -n security-policies -l app=external-authz
   ```

3. **Recovery**:
   ```bash
   # Deploy clean image
   kubectl set image deployment/zuul-gateway zuul-gateway=clean-image -n zuul-security

   # Restore network policies
   kubectl apply -f k8s/zero-trust/network-policies.yaml
   ```

## 📚 Documentation

- [Security Architecture](docs/security-architecture.md)
- [SBOM and Vulnerability Management](docs/sbom-scanning.md)
- [Zero Trust Configuration](docs/zero-trust.md)
- [Canary Deployment Guide](docs/canary-deployments.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

## 🤝 Contributing

1. Fork the repository
2. Create a security-focused feature branch
3. Implement with security tests
4. Submit pull request with security review

## 📝 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## ⚠️ Security Disclaimer

This is a reference implementation. Always:
- Review and customize security policies for your environment
- Regularly update vulnerability databases
- Monitor security alerts and incidents
- Conduct security audits and penetration testing
- Follow your organization's security guidelines

## 📞 Support

For security-related issues:
- Create a security advisory via GitHub
- Contact the security team: security@yourdomain.com
- Emergency security hotline: +1-xxx-xxx-xxxx

---

**🛡️ Security First: Never compromise on security. Always verify. Trust nothing.**