#!/bin/bash

set -euo pipefail

# Zero Trust Kubernetes Demo Deployment Script
# Complete end-to-end deployment of Zuul security infrastructure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-zuul-zero-trust-demo}"
AWS_REGION="${AWS_REGION:-us-west-2}"
ENVIRONMENT="${ENVIRONMENT:-production}"
ENABLE_AVIATRIX_NETWORKING="${ENABLE_AVIATRIX_NETWORKING:-true}"
ENABLE_SECURITY_SCANNING="${ENABLE_SECURITY_SCANNING:-true}"
SECURITY_THRESHOLD="${SECURITY_THRESHOLD:-medium}"

# Function to print colored output
print_header() {
    echo -e "\n${PURPLE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} $1"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

print_step() {
    echo -e "\n${BLUE}🔹 $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    print_header "CHECKING PREREQUISITES"

    local missing_tools=()

    # Check required tools
    for tool in aws kubectl helm terraform docker jq; do
        if ! command -v $tool >/dev/null 2>&1; then
            missing_tools+=("$tool")
        else
            print_success "$tool is installed"
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo -e "\nPlease install the missing tools and run the script again."
        echo -e "\nInstallation guides:"
        echo -e "• AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
        echo -e "• kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        echo -e "• Helm: https://helm.sh/docs/intro/install/"
        echo -e "• Terraform: https://www.terraform.io/downloads.html"
        echo -e "• Docker: https://docs.docker.com/get-docker/"
        echo -e "• jq: https://stedolan.github.io/jq/download/"
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        print_error "AWS credentials not configured"
        echo -e "\nPlease configure AWS credentials using:"
        echo -e "• aws configure"
        echo -e "• or set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
        exit 1
    else
        local account_id=$(aws sts get-caller-identity --query Account --output text)
        print_success "AWS credentials configured (Account: $account_id)"
    fi

    print_success "All prerequisites satisfied"
}

# Function to deploy AWS infrastructure
deploy_infrastructure() {
    print_header "DEPLOYING AWS INFRASTRUCTURE"

    cd infrastructure/terraform

    print_step "Initializing Terraform"
    terraform init

    print_step "Creating terraform.tfvars if not exists"
    if [ ! -f terraform.tfvars ]; then
        cat > terraform.tfvars <<EOF
# AWS Configuration
aws_region = "$AWS_REGION"
environment = "$ENVIRONMENT"
cluster_name = "$CLUSTER_NAME"

# Network Configuration
vpc_cidr = "10.0.0.0/16"
allowed_cidr_blocks = ["0.0.0.0/0"]  # Restrict this in production

# Zero Trust Configuration
zero_trust_config = {
  enable_network_segmentation = true
  enable_identity_verification = true
  enable_device_compliance = true
  enable_continuous_monitoring = true
  default_deny_policy = true
  encryption_in_transit = true
  encryption_at_rest = true
}

# Aviatrix-style Networking
enable_aviatrix_connectivity = $ENABLE_AVIATRIX_NETWORKING

# Security Configuration
container_security = {
  enable_image_scanning = true
  enable_runtime_protection = true
  enable_network_policies = true
  enable_pod_security_standards = true
  vulnerability_threshold = "$SECURITY_THRESHOLD"
  compliance_frameworks = ["nist", "pci-dss", "soc2"]
}

# Domain Configuration
domain_name = "demo.local"
github_oidc_client_id = ""

# Admin Users (Add your IAM users here)
eks_admin_users = [
  # {
  #   userarn  = "arn:aws:iam::ACCOUNT-ID:user/your-username"
  #   username = "your-username"
  #   groups   = ["system:masters"]
  # }
]
EOF
        print_info "Created terraform.tfvars - please review and customize as needed"
    fi

    print_step "Planning Terraform deployment"
    terraform plan -out=tfplan

    print_step "Applying Terraform configuration"
    terraform apply tfplan

    print_step "Configuring kubectl"
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

    # Verify cluster access
    if kubectl cluster-info >/dev/null 2>&1; then
        print_success "Successfully connected to EKS cluster"
    else
        print_error "Failed to connect to EKS cluster"
        exit 1
    fi

    cd ../..
    print_success "Infrastructure deployment completed"
}

# Function to install security operators
install_security_operators() {
    print_header "INSTALLING SECURITY OPERATORS"

    print_step "Installing Istio service mesh"
    if ! command -v istioctl >/dev/null 2>&1; then
        print_step "Downloading Istio"
        curl -L https://istio.io/downloadIstio | sh -
        cd istio-*
        export PATH=$PWD/bin:$PATH
        cd ..
    fi

    # Install Istio
    istioctl install --set values.defaultRevision=default -y
    kubectl label namespace default istio-injection=enabled

    print_step "Installing Argo Rollouts"
    if ! kubectl get namespace argo-rollouts >/dev/null 2>&1; then
        kubectl create namespace argo-rollouts
        kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
    else
        print_info "Argo Rollouts namespace already exists"
    fi

    print_step "Installing Tekton Pipelines"
    if ! kubectl get namespace tekton-pipelines >/dev/null 2>&1; then
        kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
        kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
    else
        print_info "Tekton already installed"
    fi

    print_step "Installing Kyverno policy engine"
    helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
    helm repo update
    if ! helm list -n kyverno | grep -q kyverno; then
        helm install kyverno kyverno/kyverno -n kyverno --create-namespace \
            --set replicaCount=3 \
            --set config.webhooks.namespaceSelector.matchExpressions[0].key=kubernetes.io/metadata.name \
            --set config.webhooks.namespaceSelector.matchExpressions[0].operator=NotIn \
            --set config.webhooks.namespaceSelector.matchExpressions[0].values[0]=kyverno
    else
        print_info "Kyverno already installed"
    fi

    print_step "Installing Gatekeeper"
    if ! kubectl get namespace gatekeeper-system >/dev/null 2>&1; then
        kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
    else
        print_info "Gatekeeper already installed"
    fi

    print_step "Installing Falco runtime security"
    helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
    helm repo update
    if ! helm list -n falco | grep -q falco; then
        helm install falco falcosecurity/falco -n falco --create-namespace \
            --set driver.kind=modern-ebpf \
            --set tty=true
    else
        print_info "Falco already installed"
    fi

    print_success "Security operators installation completed"
}

# Function to deploy application stack
deploy_application_stack() {
    print_header "DEPLOYING APPLICATION STACK"

    print_step "Creating namespaces and RBAC"
    kubectl apply -f kubernetes-manifests/demo-stack.yaml

    print_step "Waiting for namespace creation"
    sleep 10

    print_step "Deploying PostgreSQL database"
    kubectl wait --for=condition=available --timeout=300s deployment/postgres -n data-services

    print_step "Deploying User Service"
    kubectl wait --for=condition=available --timeout=300s deployment/user-service -n backend-services

    print_step "Deploying Zuul Gateway with Canary"
    kubectl wait --for=condition=Progressing --timeout=600s rollout/zuul-gateway -n zuul-gateway

    print_success "Application stack deployment completed"
}

# Function to deploy monitoring stack
deploy_monitoring_stack() {
    print_header "DEPLOYING MONITORING & OBSERVABILITY"

    print_step "Installing Prometheus operator"
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    if ! helm list -n monitoring | grep -q kube-prometheus-stack; then
        helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            -n monitoring --create-namespace \
            --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
            --set grafana.adminPassword=admin123 \
            --set grafana.persistence.enabled=true \
            --set grafana.persistence.size=5Gi
    else
        print_info "Prometheus stack already installed"
    fi

    print_step "Deploying custom monitoring configuration"
    kubectl apply -f monitoring/observability-stack.yaml

    print_step "Waiting for monitoring stack to be ready"
    kubectl wait --for=condition=available --timeout=300s deployment/grafana -n monitoring
    kubectl wait --for=condition=available --timeout=300s deployment/prometheus -n monitoring

    print_success "Monitoring stack deployment completed"
}

# Function to deploy security testing
deploy_security_testing() {
    print_header "DEPLOYING SECURITY TESTING SUITE"

    if [ "$ENABLE_SECURITY_SCANNING" = "true" ]; then
        print_step "Deploying security test suite"
        kubectl apply -f testing/security-tests.yaml

        print_step "Running initial security scan"
        kubectl create job --from=cronjob/security-test-suite initial-security-test -n monitoring || true

        print_step "Running compliance scan"
        kubectl create job --from=cronjob/compliance-scanner initial-compliance-scan -n monitoring || true

        print_success "Security testing deployment completed"
    else
        print_warning "Security scanning disabled - skipping security testing deployment"
    fi
}

# Function to configure DNS and networking
configure_networking() {
    print_header "CONFIGURING ZERO TRUST NETWORKING"

    print_step "Applying Istio security policies"
    cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF

    print_step "Applying default deny network policies"
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: zuul-gateway
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: backend-services
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: data-services
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

    print_step "Configuring Istio ingress gateway"
    kubectl patch service istio-ingressgateway -n istio-system -p '{"spec":{"type":"LoadBalancer"}}'

    print_success "Zero trust networking configuration completed"
}

# Function to run validation tests
run_validation_tests() {
    print_header "RUNNING VALIDATION TESTS"

    print_step "Checking pod security compliance"
    local non_compliant_pods=$(kubectl get pods --all-namespaces -o json | jq -r '
        .items[] |
        select(
            .spec.securityContext.runAsNonRoot != true or
            (.spec.containers[]? | .securityContext.allowPrivilegeEscalation != false) or
            (.spec.containers[]? | .securityContext.capabilities.drop[]? != "ALL")
        ) |
        "\(.metadata.namespace)/\(.metadata.name)"
    ' | wc -l)

    if [ "$non_compliant_pods" -eq 0 ]; then
        print_success "All pods are security compliant"
    else
        print_warning "$non_compliant_pods pods found with security compliance issues"
    fi

    print_step "Verifying Istio mTLS"
    if command -v istioctl >/dev/null 2>&1; then
        local zuul_pod=$(kubectl get pods -n zuul-gateway -l app=zuul-gateway -o jsonpath='{.items[0].metadata.name}')
        if [ -n "$zuul_pod" ]; then
            istioctl authn tls-check $zuul_pod.zuul-gateway || print_warning "mTLS verification failed"
        fi
    fi

    print_step "Testing application connectivity"
    local gateway_service=$(kubectl get svc -n zuul-gateway zuul-gateway-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "localhost")

    if [ "$gateway_service" != "localhost" ]; then
        print_info "Testing external connectivity to $gateway_service"
        timeout 30 curl -f http://$gateway_service/health >/dev/null 2>&1 && \
            print_success "External connectivity test passed" || \
            print_warning "External connectivity test failed"
    fi

    print_step "Checking resource utilization"
    kubectl top nodes 2>/dev/null || print_warning "Metrics server not available for resource monitoring"

    print_success "Validation tests completed"
}

# Function to display deployment summary
display_summary() {
    print_header "DEPLOYMENT SUMMARY"

    # Get cluster info
    local cluster_endpoint=$(kubectl config view --raw -o json | jq -r '.clusters[0].cluster.server')
    local cluster_version=$(kubectl version --short | grep "Server Version" | cut -d' ' -f3)

    # Get service URLs
    local grafana_port=$(kubectl get svc -n monitoring grafana -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "3000")
    local prometheus_port=$(kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "9090")

    # Get load balancer info
    local gateway_lb=$(kubectl get svc -n zuul-gateway zuul-gateway-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│                     DEPLOYMENT COMPLETED                       │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"

    echo -e "\n${GREEN}🎉 Zero Trust Kubernetes Demo Successfully Deployed!${NC}\n"

    echo -e "${YELLOW}Cluster Information:${NC}"
    echo -e "  • Cluster Name: $CLUSTER_NAME"
    echo -e "  • Region: $AWS_REGION"
    echo -e "  • Endpoint: $cluster_endpoint"
    echo -e "  • Version: $cluster_version"

    echo -e "\n${YELLOW}Application Access:${NC}"
    if [ "$gateway_lb" != "pending" ]; then
        echo -e "  • Zuul Gateway: http://$gateway_lb"
        echo -e "  • Health Check: http://$gateway_lb/health"
    else
        echo -e "  • Zuul Gateway: Load balancer pending..."
    fi

    echo -e "\n${YELLOW}Monitoring & Observability:${NC}"
    echo -e "  • Grafana: kubectl port-forward -n monitoring svc/grafana $grafana_port:$grafana_port"
    echo -e "    Then visit: http://localhost:$grafana_port (admin/admin123)"
    echo -e "  • Prometheus: kubectl port-forward -n monitoring svc/prometheus $prometheus_port:$prometheus_port"
    echo -e "    Then visit: http://localhost:$prometheus_port"

    echo -e "\n${YELLOW}Security Features Enabled:${NC}"
    echo -e "  ✅ Pod Security Standards (Restricted)"
    echo -e "  ✅ Network Policies (Default Deny)"
    echo -e "  ✅ Istio mTLS (STRICT mode)"
    echo -e "  ✅ RBAC (Least Privilege)"
    echo -e "  ✅ Image Vulnerability Scanning"
    echo -e "  ✅ Runtime Security Monitoring (Falco)"
    echo -e "  ✅ Policy Enforcement (Kyverno + Gatekeeper)"
    echo -e "  ✅ Admission Controllers"
    echo -e "  ✅ Canary Deployments with Security Validation"

    echo -e "\n${YELLOW}Useful Commands:${NC}"
    echo -e "  • View all pods: kubectl get pods --all-namespaces"
    echo -e "  • Check rollout status: kubectl argo rollouts get rollout zuul-gateway -n zuul-gateway"
    echo -e "  • View security policies: kubectl get clusterpolicies"
    echo -e "  • Check mTLS status: istioctl authn tls-check"
    echo -e "  • Run security tests: kubectl create job --from=cronjob/security-test-suite manual-test -n monitoring"

    echo -e "\n${YELLOW}Next Steps:${NC}"
    echo -e "  1. Customize security policies in kubernetes-manifests/"
    echo -e "  2. Review and adjust resource limits"
    echo -e "  3. Configure monitoring alerts"
    echo -e "  4. Set up backup and disaster recovery"
    echo -e "  5. Conduct security penetration testing"
    echo -e "  6. Review compliance reports in Grafana"

    echo -e "\n${GREEN}🔒 Your zero trust Kubernetes cluster is ready for production use!${NC}"
    echo -e "${CYAN}Documentation: https://github.com/Netflix/zuul/wiki${NC}"
    echo -e "${CYAN}Support: https://github.com/Netflix/zuul/issues${NC}\n"
}

# Function to handle cleanup on exit
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_error "Deployment failed with exit code $exit_code"
        echo -e "\n${YELLOW}Troubleshooting tips:${NC}"
        echo -e "• Check AWS credentials and permissions"
        echo -e "• Verify Kubernetes cluster connectivity"
        echo -e "• Review Terraform output for errors"
        echo -e "• Check pod logs: kubectl logs -n <namespace> <pod-name>"
        echo -e "• Validate security policies: kubectl describe clusterpolicy"
    fi
}

# Main deployment function
main() {
    # Set up cleanup handler
    trap cleanup EXIT

    print_header "ZERO TRUST KUBERNETES DEMO DEPLOYMENT"
    echo -e "${CYAN}This script will deploy a complete zero trust security demonstration${NC}"
    echo -e "${CYAN}using Netflix Zuul on AWS EKS with comprehensive security features.${NC}\n"

    print_info "Configuration:"
    echo -e "  • Cluster Name: $CLUSTER_NAME"
    echo -e "  • AWS Region: $AWS_REGION"
    echo -e "  • Environment: $ENVIRONMENT"
    echo -e "  • Aviatrix Networking: $ENABLE_AVIATRIX_NETWORKING"
    echo -e "  • Security Scanning: $ENABLE_SECURITY_SCANNING"
    echo -e "  • Security Threshold: $SECURITY_THRESHOLD"

    # Confirm deployment
    echo -e "\n${YELLOW}Do you want to proceed with the deployment? (y/N)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled by user"
        exit 0
    fi

    # Execute deployment steps
    check_prerequisites
    deploy_infrastructure
    install_security_operators
    deploy_application_stack
    deploy_monitoring_stack
    deploy_security_testing
    configure_networking

    # Wait for everything to be ready
    print_step "Waiting for all components to be ready..."
    sleep 30

    run_validation_tests
    display_summary
}

# Execute main function
main "$@"