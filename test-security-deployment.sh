#!/bin/bash

set -euo pipefail

# Zuul Security Infrastructure Testing Script
# Comprehensive testing suite for the security deployment

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test configuration
NAMESPACE_ZUUL="zuul-security"
NAMESPACE_SCANNING="security-scanning"
NAMESPACE_POLICIES="security-policies"
TEST_RESULTS_DIR="test-results-$(date +%Y%m%d-%H%M%S)"

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
print_test() {
    echo -e "\n${BLUE}[TEST]${NC} $1"
    ((TESTS_TOTAL++))
}

pass_test() {
    echo -e "${GREEN}✓ PASS${NC} $1"
    ((TESTS_PASSED++))
}

fail_test() {
    echo -e "${RED}✗ FAIL${NC} $1"
    ((TESTS_FAILED++))
}

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Create test results directory
mkdir -p ${TEST_RESULTS_DIR}

# Test 1: Verify all namespaces exist
test_namespaces() {
    print_test "Verifying namespaces exist"

    local namespaces=("${NAMESPACE_ZUUL}" "${NAMESPACE_SCANNING}" "${NAMESPACE_POLICIES}")
    local all_exist=true

    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "${ns}" >/dev/null 2>&1; then
            echo "  ✓ Namespace ${ns} exists"
        else
            echo "  ✗ Namespace ${ns} missing"
            all_exist=false
        fi
    done

    if [ "$all_exist" = true ]; then
        pass_test "All required namespaces exist"
    else
        fail_test "Some namespaces are missing"
    fi
}

# Test 2: Verify Pod Security Standards enforcement
test_pod_security_standards() {
    print_test "Testing Pod Security Standards enforcement"

    # Create a test pod that violates security standards
    local violation_pod=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: security-violation-test
  namespace: ${NAMESPACE_ZUUL}
spec:
  securityContext:
    runAsUser: 0  # This should be rejected
  containers:
  - name: test
    image: nginx
    securityContext:
      privileged: true  # This should be rejected
EOF
)

    echo "${violation_pod}" | kubectl apply -f - 2>&1 | tee ${TEST_RESULTS_DIR}/pod-security-test.log

    if grep -q "denied\|forbidden\|violation" ${TEST_RESULTS_DIR}/pod-security-test.log; then
        pass_test "Pod Security Standards are properly enforced"
    else
        fail_test "Pod Security Standards enforcement is not working"
    fi

    # Cleanup
    kubectl delete pod security-violation-test -n ${NAMESPACE_ZUUL} 2>/dev/null || true
}

# Test 3: Verify Network Policies
test_network_policies() {
    print_test "Testing Network Policies"

    # Check if default deny policy exists
    if kubectl get networkpolicy default-deny-all -n ${NAMESPACE_ZUUL} >/dev/null 2>&1; then
        pass_test "Default deny network policy exists"
    else
        fail_test "Default deny network policy missing"
    fi

    # Test network connectivity (this is a simplified test)
    local test_pod="network-test-$(date +%s)"
    kubectl run ${test_pod} --image=alpine --rm -it --restart=Never -n ${NAMESPACE_ZUUL} -- sh -c "
        apk add --no-cache curl
        # This should fail due to network policies
        timeout 5 curl http://httpbin.org/ip || echo 'Network policy blocking external access - GOOD'
    " 2>&1 | tee ${TEST_RESULTS_DIR}/network-policy-test.log

    if grep -q "Network policy blocking" ${TEST_RESULTS_DIR}/network-policy-test.log; then
        pass_test "Network policies are blocking unauthorized traffic"
    else
        fail_test "Network policies may not be working correctly"
    fi
}

# Test 4: Verify Istio mTLS
test_istio_mtls() {
    print_test "Testing Istio mTLS configuration"

    if command -v istioctl >/dev/null 2>&1; then
        # Get a pod to test with
        local pod=$(kubectl get pods -n ${NAMESPACE_ZUUL} -l app=zuul-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$pod" ]; then
            istioctl authn tls-check ${pod}.${NAMESPACE_ZUUL} 2>&1 | tee ${TEST_RESULTS_DIR}/mtls-test.log

            if grep -q "OK\|STRICT" ${TEST_RESULTS_DIR}/mtls-test.log; then
                pass_test "Istio mTLS is properly configured"
            else
                fail_test "Istio mTLS configuration issues detected"
            fi
        else
            fail_test "No Zuul Gateway pods found for mTLS testing"
        fi
    else
        fail_test "istioctl not available for mTLS testing"
    fi
}

# Test 5: Verify SBOM generation
test_sbom_generation() {
    print_test "Testing SBOM generation"

    # Check if SBOM scanner cron job exists
    if kubectl get cronjob sbom-scanner -n ${NAMESPACE_SCANNING} >/dev/null 2>&1; then
        pass_test "SBOM scanner cron job exists"

        # Trigger a manual SBOM scan
        kubectl create job --from=cronjob/sbom-scanner manual-sbom-test -n ${NAMESPACE_SCANNING} 2>/dev/null || true

        # Wait a bit and check if job completed
        sleep 30
        local job_status=$(kubectl get job manual-sbom-test -n ${NAMESPACE_SCANNING} -o jsonpath='{.status.conditions[0].type}' 2>/dev/null)

        if [ "$job_status" = "Complete" ]; then
            pass_test "SBOM generation job completed successfully"
        else
            fail_test "SBOM generation job did not complete"
        fi

        # Cleanup
        kubectl delete job manual-sbom-test -n ${NAMESPACE_SCANNING} 2>/dev/null || true
    else
        fail_test "SBOM scanner cron job not found"
    fi
}

# Test 6: Verify vulnerability scanning
test_vulnerability_scanning() {
    print_test "Testing vulnerability scanning"

    if kubectl get cronjob vulnerability-scanner -n ${NAMESPACE_SCANNING} >/dev/null 2>&1; then
        pass_test "Vulnerability scanner cron job exists"

        # Check if Grype is working by running a quick scan
        kubectl run vuln-test --image=anchore/grype --rm -it --restart=Never -n ${NAMESPACE_SCANNING} -- \
            grype --help >/dev/null 2>&1 && \
            pass_test "Grype vulnerability scanner is functional" || \
            fail_test "Grype vulnerability scanner is not working"
    else
        fail_test "Vulnerability scanner cron job not found"
    fi
}

# Test 7: Verify external authorization service
test_external_authz() {
    print_test "Testing external authorization service"

    if kubectl get deployment external-authz-service -n ${NAMESPACE_POLICIES} >/dev/null 2>&1; then
        local ready_replicas=$(kubectl get deployment external-authz-service -n ${NAMESPACE_POLICIES} -o jsonpath='{.status.readyReplicas}')
        local desired_replicas=$(kubectl get deployment external-authz-service -n ${NAMESPACE_POLICIES} -o jsonpath='{.spec.replicas}')

        if [ "$ready_replicas" = "$desired_replicas" ] && [ "$ready_replicas" -gt 0 ]; then
            pass_test "External authorization service is running (${ready_replicas}/${desired_replicas} replicas)"
        else
            fail_test "External authorization service is not ready (${ready_replicas}/${desired_replicas} replicas)"
        fi

        # Test service connectivity
        local svc_ip=$(kubectl get svc ext-authz -n ${NAMESPACE_POLICIES} -o jsonpath='{.spec.clusterIP}')
        kubectl run authz-test --image=alpine --rm -it --restart=Never -n ${NAMESPACE_POLICIES} -- \
            sh -c "apk add --no-cache curl && curl -s ${svc_ip}:9000 || echo 'Service unreachable'" 2>&1 | \
            tee ${TEST_RESULTS_DIR}/authz-connectivity-test.log

        if ! grep -q "Service unreachable" ${TEST_RESULTS_DIR}/authz-connectivity-test.log; then
            pass_test "External authorization service is reachable"
        else
            fail_test "External authorization service is not reachable"
        fi
    else
        fail_test "External authorization service deployment not found"
    fi
}

# Test 8: Verify Tekton pipeline
test_security_pipeline() {
    print_test "Testing Tekton security pipeline"

    if kubectl get pipeline zuul-security-pipeline -n ${NAMESPACE_ZUUL} >/dev/null 2>&1; then
        pass_test "Zuul security pipeline exists"

        # Check if EventListener is running
        if kubectl get deployment el-zuul-security-eventlistener -n ${NAMESPACE_ZUUL} >/dev/null 2>&1; then
            pass_test "Security pipeline EventListener is deployed"
        else
            fail_test "Security pipeline EventListener not found"
        fi
    else
        fail_test "Zuul security pipeline not found"
    fi
}

# Test 9: Verify Argo Rollouts
test_canary_deployment() {
    print_test "Testing canary deployment setup"

    if kubectl get rollout zuul-gateway-rollout -n ${NAMESPACE_ZUUL} >/dev/null 2>&1; then
        local rollout_status=$(kubectl get rollout zuul-gateway-rollout -n ${NAMESPACE_ZUUL} -o jsonpath='{.status.phase}')

        if [ "$rollout_status" = "Healthy" ] || [ "$rollout_status" = "Progressing" ]; then
            pass_test "Zuul Gateway rollout is ${rollout_status}"
        else
            fail_test "Zuul Gateway rollout status is ${rollout_status}"
        fi

        # Check if analysis templates exist
        if kubectl get analysistemplate security-analysis -n ${NAMESPACE_ZUUL} >/dev/null 2>&1; then
            pass_test "Security analysis template exists"
        else
            fail_test "Security analysis template not found"
        fi
    else
        fail_test "Zuul Gateway rollout not found"
    fi
}

# Test 10: Verify admission controllers
test_admission_controllers() {
    print_test "Testing admission controllers"

    # Test Kyverno policies
    if kubectl get clusterpolicy enforce-security-standards >/dev/null 2>&1; then
        pass_test "Kyverno security policies are installed"
    else
        fail_test "Kyverno security policies not found"
    fi

    # Test Gatekeeper constraints
    if kubectl get securitycompliancecheck zuul-security-compliance >/dev/null 2>&1; then
        pass_test "Gatekeeper security constraints are installed"
    else
        fail_test "Gatekeeper security constraints not found"
    fi
}

# Test 11: Security labels and annotations
test_security_metadata() {
    print_test "Testing security labels and annotations"

    local pods=$(kubectl get pods -n ${NAMESPACE_ZUUL} -l app=zuul-gateway -o name)
    local all_labeled=true

    for pod in $pods; do
        local labels=$(kubectl get $pod -n ${NAMESPACE_ZUUL} -o jsonpath='{.metadata.labels}')

        if echo "$labels" | grep -q "security.scan.status" && echo "$labels" | grep -q "security.compliance.level"; then
            echo "  ✓ $pod has required security labels"
        else
            echo "  ✗ $pod missing security labels"
            all_labeled=false
        fi
    done

    if [ "$all_labeled" = true ]; then
        pass_test "All pods have required security labels"
    else
        fail_test "Some pods are missing security labels"
    fi
}

# Test 12: Resource limits and security context
test_resource_security() {
    print_test "Testing resource limits and security context"

    local pods=$(kubectl get pods -n ${NAMESPACE_ZUUL} -l app=zuul-gateway -o jsonpath='{.items[*].metadata.name}')
    local all_secure=true

    for pod in $pods; do
        local security_context=$(kubectl get pod $pod -n ${NAMESPACE_ZUUL} -o jsonpath='{.spec.securityContext}')
        local container_limits=$(kubectl get pod $pod -n ${NAMESPACE_ZUUL} -o jsonpath='{.spec.containers[*].resources.limits}')

        if echo "$security_context" | grep -q "runAsNonRoot.*true" && [ -n "$container_limits" ]; then
            echo "  ✓ $pod has proper security context and resource limits"
        else
            echo "  ✗ $pod has security issues"
            all_secure=false
        fi
    done

    if [ "$all_secure" = true ]; then
        pass_test "All pods have proper security configuration"
    else
        fail_test "Some pods have security configuration issues"
    fi
}

# Generate security report
generate_security_report() {
    print_section "Generating Security Test Report"

    local report_file="${TEST_RESULTS_DIR}/security-test-report.html"

    cat > ${report_file} <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Zuul Security Infrastructure Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .pass { color: green; }
        .fail { color: red; }
        .section { margin: 20px 0; }
        .test-result { margin: 10px 0; padding: 10px; border-left: 4px solid #ccc; }
        .test-result.pass { border-left-color: green; background-color: #f0fff0; }
        .test-result.fail { border-left-color: red; background-color: #fff0f0; }
        .summary { font-size: 18px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Zuul Security Infrastructure Test Report</h1>
        <p>Generated: $(date)</p>
        <div class="summary">
            Total Tests: ${TESTS_TOTAL} |
            <span class="pass">Passed: ${TESTS_PASSED}</span> |
            <span class="fail">Failed: ${TESTS_FAILED}</span>
        </div>
    </div>

    <div class="section">
        <h2>Test Results</h2>
EOF

    # Add individual test results (this would be populated during test execution)
    echo "        <p>Detailed test results are available in the ${TEST_RESULTS_DIR} directory.</p>" >> ${report_file}

    cat >> ${report_file} <<EOF
    </div>

    <div class="section">
        <h2>Security Recommendations</h2>
        <ul>
            <li>Regularly update vulnerability databases</li>
            <li>Monitor security scan results daily</li>
            <li>Review and update security policies quarterly</li>
            <li>Conduct penetration testing annually</li>
            <li>Keep all security tools and dependencies updated</li>
        </ul>
    </div>
</body>
</html>
EOF

    echo "Security test report generated: ${report_file}"
}

# Main test execution
main() {
    print_section "Starting Zuul Security Infrastructure Tests"

    test_namespaces
    test_pod_security_standards
    test_network_policies
    test_istio_mtls
    test_sbom_generation
    test_vulnerability_scanning
    test_external_authz
    test_security_pipeline
    test_canary_deployment
    test_admission_controllers
    test_security_metadata
    test_resource_security

    print_section "Test Summary"
    echo -e "Total Tests: ${TESTS_TOTAL}"
    echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
    echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"

    local success_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    echo -e "Success Rate: ${success_rate}%"

    if [ ${TESTS_FAILED} -eq 0 ]; then
        echo -e "\n${GREEN}🎉 All security tests passed! Your Zuul deployment is secure.${NC}"
        exit 0
    else
        echo -e "\n${RED}⚠️  Some security tests failed. Please review and fix the issues.${NC}"
        exit 1
    fi

    generate_security_report
}

# Execute main function
main "$@"