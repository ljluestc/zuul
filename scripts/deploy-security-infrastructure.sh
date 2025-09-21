#!/bin/bash

set -euo pipefail

# Zuul Security Infrastructure Deployment Script
# This script deploys the complete security infrastructure for Zuul Gateway
# including SBOM scanning, canary deployments, and zero-trust microsegmentation

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE_ZUUL="zuul-security"
NAMESPACE_SCANNING="security-scanning"
NAMESPACE_POLICIES="security-policies"
REGISTRY="your-registry.com"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Function to check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"

    local missing_tools=()

    command -v kubectl >/dev/null 2>&1 || missing_tools+=("kubectl")
    command -v docker >/dev/null 2>&1 || missing_tools+=("docker")
    command -v helm >/dev/null 2>&1 || missing_tools+=("helm")

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi

    # Check if cluster is accessible
    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_error "Cannot access Kubernetes cluster"
        exit 1
    fi

    print_status "All prerequisites satisfied"
}

# Function to install required operators and tools
install_operators() {
    print_section "Installing Required Operators"

    # Install Istio
    print_status "Installing Istio..."
    if ! kubectl get ns istio-system >/dev/null 2>&1; then
        curl -L https://istio.io/downloadIstio | sh -
        cd istio-*
        export PATH=$PWD/bin:$PATH
        istioctl install --set values.defaultRevision=default -y
        kubectl label namespace default istio-injection=enabled
        cd ..
    else
        print_status "Istio already installed"
    fi

    # Install Argo Rollouts
    print_status "Installing Argo Rollouts..."
    if ! kubectl get ns argo-rollouts >/dev/null 2>&1; then
        kubectl create namespace argo-rollouts
        kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
    else
        print_status "Argo Rollouts already installed"
    fi

    # Install Tekton
    print_status "Installing Tekton..."
    if ! kubectl get ns tekton-pipelines >/dev/null 2>&1; then
        kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
        kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
    else
        print_status "Tekton already installed"
    fi

    # Install Kyverno
    print_status "Installing Kyverno..."
    if ! kubectl get ns kyverno >/dev/null 2>&1; then
        helm repo add kyverno https://kyverno.github.io/kyverno/
        helm repo update
        helm install kyverno kyverno/kyverno -n kyverno --create-namespace
    else
        print_status "Kyverno already installed"
    fi

    # Install Gatekeeper
    print_status "Installing Gatekeeper..."
    if ! kubectl get ns gatekeeper-system >/dev/null 2>&1; then
        kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
    else
        print_status "Gatekeeper already installed"
    fi
}

# Function to create namespaces
create_namespaces() {
    print_section "Creating Namespaces"

    kubectl apply -f k8s/namespace.yaml

    # Label namespaces for security scanning
    kubectl label namespace ${NAMESPACE_ZUUL} security-scan=required --overwrite
    kubectl label namespace ${NAMESPACE_SCANNING} security-scan=required --overwrite
    kubectl label namespace ${NAMESPACE_POLICIES} security-scan=required --overwrite

    print_status "Namespaces created and labeled"
}

# Function to build and push Docker image
build_and_push_image() {
    print_section "Building and Pushing Docker Image"

    # Build the image with security scanning
    print_status "Building Zuul Gateway image..."
    docker build -t ${REGISTRY}/zuul-gateway:${IMAGE_TAG} .

    # Sign the image with cosign (if available)
    if command -v cosign >/dev/null 2>&1; then
        print_status "Signing image with cosign..."
        cosign sign --yes ${REGISTRY}/zuul-gateway:${IMAGE_TAG}
    else
        print_warning "cosign not available, skipping image signing"
    fi

    # Push the image
    print_status "Pushing image to registry..."
    docker push ${REGISTRY}/zuul-gateway:${IMAGE_TAG}

    print_status "Image built and pushed successfully"
}

# Function to deploy RBAC and security policies
deploy_security_policies() {
    print_section "Deploying Security Policies"

    # Apply RBAC
    kubectl apply -f k8s/rbac.yaml

    # Apply Pod Security Standards
    kubectl apply -f k8s/security-policies/pod-security-standards.yaml

    # Apply Network Policies
    kubectl apply -f k8s/zero-trust/network-policies.yaml

    print_status "Security policies deployed"
}

# Function to deploy Istio security configuration
deploy_istio_security() {
    print_section "Deploying Istio Security Configuration"

    kubectl apply -f k8s/zero-trust/istio-security.yaml

    # Wait for Istio configuration to be applied
    print_status "Waiting for Istio configuration to be ready..."
    sleep 30

    print_status "Istio security configuration deployed"
}

# Function to deploy external authorization service
deploy_external_authz() {
    print_section "Deploying External Authorization Service"

    kubectl apply -f k8s/external-authz/authz-service.yaml

    # Wait for external authz service to be ready
    print_status "Waiting for external authorization service to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/external-authz-service -n ${NAMESPACE_POLICIES}

    print_status "External authorization service deployed"
}

# Function to deploy security scanning infrastructure
deploy_security_scanning() {
    print_section "Deploying Security Scanning Infrastructure"

    # Apply ConfigMaps
    kubectl apply -f k8s/configmap.yaml

    # Deploy SBOM scanners
    kubectl apply -f k8s/security-scanning/sbom-scanner.yaml

    # Deploy admission controller
    kubectl apply -f k8s/security-scanning/admission-controller.yaml

    print_status "Security scanning infrastructure deployed"
}

# Function to deploy Tekton pipeline
deploy_security_pipeline() {
    print_section "Deploying Security Pipeline"

    # Create service account for pipeline
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: zuul-security-pipeline-sa
  namespace: ${NAMESPACE_ZUUL}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: zuul-security-pipeline-binding
subjects:
- kind: ServiceAccount
  name: zuul-security-pipeline-sa
  namespace: ${NAMESPACE_ZUUL}
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

    # Deploy pipeline and triggers
    kubectl apply -f k8s/security-pipeline/tekton-pipeline.yaml
    kubectl apply -f k8s/security-pipeline/triggers.yaml

    print_status "Security pipeline deployed"
}

# Function to deploy Zuul Gateway
deploy_zuul_gateway() {
    print_section "Deploying Zuul Gateway"

    # Update image tag in deployment
    sed -i "s|your-registry.com/zuul-gateway:latest|${REGISTRY}/zuul-gateway:${IMAGE_TAG}|g" k8s/deployment.yaml

    # Apply configuration
    kubectl apply -f k8s/configmap.yaml
    kubectl apply -f k8s/deployment.yaml

    # Deploy services and canary configuration
    kubectl apply -f k8s/canary-deployment/services.yaml
    kubectl apply -f k8s/canary-deployment/rollout.yaml

    # Wait for rollout to be ready
    print_status "Waiting for Zuul Gateway rollout to be ready..."
    kubectl wait --for=condition=Progressing --timeout=600s rollout/zuul-gateway-rollout -n ${NAMESPACE_ZUUL}

    print_status "Zuul Gateway deployed successfully"
}

# Function to run security validation tests
run_security_validation() {
    print_section "Running Security Validation Tests"

    # Check if all pods are running
    print_status "Checking pod status..."
    kubectl get pods -n ${NAMESPACE_ZUUL}
    kubectl get pods -n ${NAMESPACE_SCANNING}
    kubectl get pods -n ${NAMESPACE_POLICIES}

    # Validate Istio mTLS
    print_status "Validating Istio mTLS..."
    if command -v istioctl >/dev/null 2>&1; then
        POD=$(kubectl get pods -n ${NAMESPACE_ZUUL} -l app=zuul-gateway -o jsonpath='{.items[0].metadata.name}')
        istioctl authn tls-check ${POD}.${NAMESPACE_ZUUL}
    fi

    # Test security policies
    print_status "Testing security policies..."
    kubectl auth can-i create pods --as=system:serviceaccount:${NAMESPACE_ZUUL}:zuul-gateway -n ${NAMESPACE_ZUUL}

    # Run a quick security scan
    print_status "Running quick security scan..."
    kubectl create job --from=cronjob/sbom-scanner security-scan-test -n ${NAMESPACE_SCANNING} || true

    print_status "Security validation completed"
}

# Function to generate deployment report
generate_report() {
    print_section "Generating Deployment Report"

    local report_file="deployment-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "Zuul Security Infrastructure Deployment Report"
        echo "=============================================="
        echo "Date: $(date)"
        echo "Image: ${REGISTRY}/zuul-gateway:${IMAGE_TAG}"
        echo ""

        echo "Namespaces:"
        kubectl get namespaces ${NAMESPACE_ZUUL} ${NAMESPACE_SCANNING} ${NAMESPACE_POLICIES}
        echo ""

        echo "Deployments:"
        kubectl get deployments -n ${NAMESPACE_ZUUL}
        kubectl get deployments -n ${NAMESPACE_SCANNING}
        kubectl get deployments -n ${NAMESPACE_POLICIES}
        echo ""

        echo "Services:"
        kubectl get services -n ${NAMESPACE_ZUUL}
        echo ""

        echo "Rollouts:"
        kubectl get rollouts -n ${NAMESPACE_ZUUL}
        echo ""

        echo "Network Policies:"
        kubectl get networkpolicies -A
        echo ""

        echo "Security Policies:"
        kubectl get clusterpolicies
        echo ""

        echo "PipelineRuns (last 5):"
        kubectl get pipelineruns -n ${NAMESPACE_ZUUL} --sort-by=.metadata.creationTimestamp | tail -5

    } > ${report_file}

    print_status "Deployment report generated: ${report_file}"
}

# Main deployment function
main() {
    print_section "Starting Zuul Security Infrastructure Deployment"

    check_prerequisites
    install_operators
    create_namespaces
    build_and_push_image
    deploy_security_policies
    deploy_istio_security
    deploy_external_authz
    deploy_security_scanning
    deploy_security_pipeline
    deploy_zuul_gateway
    run_security_validation
    generate_report

    print_section "Deployment Completed Successfully!"

    echo -e "\n${GREEN}Next Steps:${NC}"
    echo "1. Access Zuul Gateway at: https://gateway.yourdomain.com"
    echo "2. Monitor security scans in namespace: ${NAMESPACE_SCANNING}"
    echo "3. View canary deployment progress: kubectl argo rollouts get rollout zuul-gateway-rollout -n ${NAMESPACE_ZUUL}"
    echo "4. Check security policies: kubectl get clusterpolicies"
    echo "5. View security pipeline: kubectl get pipelineruns -n ${NAMESPACE_ZUUL}"

    echo -e "\n${YELLOW}Important Security Notes:${NC}"
    echo "- All images are scanned for vulnerabilities before deployment"
    echo "- SBOM is generated and stored for each deployment"
    echo "- Zero-trust network policies are enforced"
    echo "- mTLS is enabled for all service-to-service communication"
    echo "- External authorization is enforced for all API access"
    echo "- Canary deployments include security validation steps"
}

# Run main function
main "$@"