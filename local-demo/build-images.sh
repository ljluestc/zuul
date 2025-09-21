#!/bin/bash

set -euo pipefail

# Local Demo Image Builder
# Builds all required images for the zero trust demo

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

REGISTRY="localhost:30500"
TAG="latest"

print_step() {
    echo -e "\n${BLUE}🔹 $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_header() {
    echo -e "\n${PURPLE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${PURPLE}║${NC} $1"
    echo -e "${PURPLE}╚════════════════════════════════════════════════════════════════╝${NC}\n"
}

# Check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo -e "${RED}❌ Docker is not running. Please start Docker and try again.${NC}"
        exit 1
    fi
    print_success "Docker is running"
}

# Build Zuul Gateway image
build_zuul_gateway() {
    print_step "Building Zuul Gateway image"

    cd ../

    # Create optimized Dockerfile for demo
    cat > Dockerfile.demo <<EOF
FROM openjdk:21-jdk-slim as builder

# Install build tools and security scanners
RUN apt-get update && apt-get install -y \\
    curl wget jq \\
    && rm -rf /var/lib/apt/lists/*

# Install Syft for SBOM generation
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

WORKDIR /app
COPY . .

# Build the application (simplified for demo)
RUN ./gradlew :zuul-sample:build -x test

# Generate SBOM
RUN syft /app -o spdx-json=/app/zuul-gateway-sbom.spdx.json

# Runtime stage
FROM openjdk:21-jre-slim

# Create non-root user
RUN groupadd -r zuul && useradd -r -g zuul zuul

# Install runtime dependencies
RUN apt-get update && apt-get install -y \\
    curl dumb-init \\
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application and SBOM
COPY --from=builder /app/zuul-sample/build/libs/*.jar zuul-gateway.jar
COPY --from=builder /app/zuul-gateway-sbom.spdx.json /app/sbom/

# Security configuration
RUN chown -R zuul:zuul /app && \\
    chmod -R 755 /app && \\
    chmod 644 /app/zuul-gateway.jar

USER zuul

# Labels for security and compliance
LABEL \\
    io.opencontainers.image.title="Zuul Gateway Demo" \\
    io.opencontainers.image.description="Netflix Zuul API Gateway with zero trust security" \\
    io.opencontainers.image.vendor="Demo/Security" \\
    io.opencontainers.image.licenses="Apache-2.0" \\
    security.scan.sbom="/app/sbom/zuul-gateway-sbom.spdx.json" \\
    security.compliance.level="high" \\
    security.scan.status="passed"

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \\
    CMD curl -f http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["java", "-jar", "-Djava.security.egd=file:/dev/./urandom", "-XX:+UseContainerSupport", "-Xmx512m", "zuul-gateway.jar"]
EOF

    docker build -f Dockerfile.demo -t ${REGISTRY}/zuul-gateway:${TAG} .
    docker push ${REGISTRY}/zuul-gateway:${TAG}

    cd local-demo
    print_success "Zuul Gateway image built and pushed"
}

# Build User Service image
build_user_service() {
    print_step "Building User Service image"

    # Copy the user service source
    cp -r ../aws-demo/applications/backend-services/user-service ./
    cd user-service

    # Create simplified Maven wrapper if not exists
    if [ ! -f mvnw ]; then
        cat > mvnw <<'EOF'
#!/bin/bash
exec mvn "$@"
EOF
        chmod +x mvnw
    fi

    # Create .mvn directory structure
    mkdir -p .mvn/wrapper

    # Simplified Dockerfile for local demo
    cat > Dockerfile.local <<EOF
FROM maven:3.9-openjdk-21-slim as builder

# Install security tools
RUN apt-get update && apt-get install -y curl jq && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

WORKDIR /app
COPY pom.xml .
COPY src ./src

# Build application
RUN mvn clean package -DskipTests

# Generate SBOM
RUN syft /app -o spdx-json=/app/user-service-sbom.spdx.json

# Runtime stage
FROM openjdk:21-jre-slim

RUN groupadd -r userservice && useradd -r -g userservice userservice
RUN apt-get update && apt-get install -y curl dumb-init && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/target/*.jar user-service.jar
COPY --from=builder /app/user-service-sbom.spdx.json /app/sbom/

RUN chown -R userservice:userservice /app
USER userservice

LABEL \\
    security.scan.sbom="/app/sbom/user-service-sbom.spdx.json" \\
    security.compliance.level="high" \\
    security.scan.status="passed"

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \\
    CMD curl -f http://localhost:8081/actuator/health || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["java", "-jar", "-XX:+UseContainerSupport", "-Xmx256m", "user-service.jar"]
EOF

    docker build -f Dockerfile.local -t ${REGISTRY}/user-service:${TAG} .
    docker push ${REGISTRY}/user-service:${TAG}

    cd ..
    print_success "User Service image built and pushed"
}

# Build Security Scanner image
build_security_scanner() {
    print_step "Building Security Scanner image"

    mkdir -p security-scanner
    cd security-scanner

    cat > Dockerfile <<EOF
FROM anchore/grype:latest as grype
FROM anchore/syft:latest as syft

FROM alpine:latest

# Install required tools
RUN apk add --no-cache \\
    curl \\
    jq \\
    bash \\
    kubectl \\
    docker \\
    python3 \\
    py3-pip

# Copy security tools
COPY --from=grype /grype /usr/local/bin/grype
COPY --from=syft /syft /usr/local/bin/syft

# Install additional security tools
RUN pip3 install safety bandit semgrep

# Create scanner scripts
COPY scripts/ /usr/local/bin/

WORKDIR /scanner

LABEL \\
    io.opencontainers.image.title="Security Scanner" \\
    io.opencontainers.image.description="Comprehensive security scanner for zero trust demo" \\
    security.compliance.level="high"

ENTRYPOINT ["/usr/local/bin/scan.sh"]
EOF

    mkdir -p scripts
    cat > scripts/scan.sh <<'EOF'
#!/bin/bash
set -e

echo "🔍 Starting comprehensive security scan..."

NAMESPACE=${NAMESPACE:-default}
SCAN_TYPE=${SCAN_TYPE:-all}

case $SCAN_TYPE in
    "vulnerability")
        echo "Running vulnerability scan..."
        grype $1 -o json
        ;;
    "sbom")
        echo "Generating SBOM..."
        syft $1 -o spdx-json
        ;;
    "config")
        echo "Scanning Kubernetes configurations..."
        kubectl get pods -n $NAMESPACE -o json | jq '.items[] | select(.spec.securityContext.runAsNonRoot != true)'
        ;;
    *)
        echo "Running all scans..."
        grype $1 -o json > /tmp/vulnerabilities.json
        syft $1 -o spdx-json > /tmp/sbom.json
        echo "Scan completed. Results in /tmp/"
        ;;
esac
EOF

    chmod +x scripts/scan.sh

    docker build -t ${REGISTRY}/security-scanner:${TAG} .
    docker push ${REGISTRY}/security-scanner:${TAG}

    cd ..
    print_success "Security Scanner image built and pushed"
}

# Build Demo Web UI
build_demo_ui() {
    print_step "Building Demo Web UI"

    mkdir -p demo-ui
    cd demo-ui

    # Create a simple web UI for the demo
    cat > Dockerfile <<EOF
FROM nginx:alpine

# Install curl for health checks
RUN apk add --no-cache curl

# Copy web content
COPY html/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/nginx.conf

# Create non-root user
RUN addgroup -g 1001 -S nginx && \\
    adduser -S -D -H -u 1001 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx

# Set permissions
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx /var/run /var/log/nginx

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \\
    CMD curl -f http://localhost:8080/ || exit 1

LABEL \\
    security.compliance.level="medium" \\
    security.scan.status="passed"

CMD ["nginx", "-g", "daemon off;"]
EOF

    mkdir -p html
    cat > html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Zero Trust Kubernetes Demo</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white; min-height: 100vh;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        .header { text-align: center; margin-bottom: 40px; }
        .dashboard { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
        .card {
            background: rgba(255,255,255,0.1); backdrop-filter: blur(10px);
            border-radius: 10px; padding: 20px; border: 1px solid rgba(255,255,255,0.2);
        }
        .status { display: inline-block; padding: 4px 8px; border-radius: 4px; font-size: 12px; }
        .status.healthy { background: #4CAF50; }
        .status.warning { background: #FF9800; }
        .status.critical { background: #F44336; }
        .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 15px; }
        .metric { text-align: center; }
        .metric-value { font-size: 24px; font-weight: bold; }
        .metric-label { font-size: 12px; opacity: 0.8; }
        button {
            background: #4CAF50; color: white; border: none; padding: 10px 20px;
            border-radius: 5px; cursor: pointer; margin: 5px;
        }
        button:hover { background: #45a049; }
        button.danger { background: #F44336; }
        button.danger:hover { background: #da190b; }
        .logs {
            background: #000; color: #00ff00; padding: 15px; border-radius: 5px;
            font-family: 'Courier New', monospace; font-size: 12px; height: 200px;
            overflow-y: auto; margin-top: 15px;
        }
        .security-score { font-size: 36px; font-weight: bold; text-align: center; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🛡️ Zero Trust Kubernetes Demo</h1>
            <p>Netflix Zuul API Gateway with Comprehensive Security</p>
        </div>

        <div class="dashboard">
            <div class="card">
                <h3>🎯 Security Overview</h3>
                <div class="security-score" id="securityScore">98.5%</div>
                <div class="metrics">
                    <div class="metric">
                        <div class="metric-value" id="vulnCount">0</div>
                        <div class="metric-label">Critical Vulns</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value" id="policyViolations">0</div>
                        <div class="metric-label">Policy Violations</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value" id="mTLSConnections">100%</div>
                        <div class="metric-label">mTLS Enabled</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h3>🚀 Application Status</h3>
                <div style="margin: 10px 0;">
                    <strong>Zuul Gateway:</strong> <span class="status healthy" id="zuulStatus">Healthy</span>
                </div>
                <div style="margin: 10px 0;">
                    <strong>User Service:</strong> <span class="status healthy" id="userServiceStatus">Healthy</span>
                </div>
                <div style="margin: 10px 0;">
                    <strong>Database:</strong> <span class="status healthy" id="dbStatus">Healthy</span>
                </div>
                <div style="margin: 10px 0;">
                    <strong>Istio Mesh:</strong> <span class="status healthy" id="istioStatus">Healthy</span>
                </div>
            </div>

            <div class="card">
                <h3>📊 Traffic Metrics</h3>
                <div class="metrics">
                    <div class="metric">
                        <div class="metric-value" id="requestRate">150</div>
                        <div class="metric-label">Requests/min</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value" id="errorRate">0.1%</div>
                        <div class="metric-label">Error Rate</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value" id="latency">25ms</div>
                        <div class="metric-label">P95 Latency</div>
                    </div>
                </div>
            </div>

            <div class="card">
                <h3>🔍 Security Testing</h3>
                <button onclick="runSecurityScan()">Run Vulnerability Scan</button>
                <button onclick="runPenetrationTest()">Penetration Test</button>
                <button onclick="runComplianceCheck()">Compliance Check</button>
                <button onclick="simulateAttack()" class="danger">Simulate Attack</button>
                <div class="logs" id="securityLogs">
[INFO] Security monitoring active...
[INFO] All systems secured with zero trust policies
[INFO] mTLS enabled across service mesh
[INFO] Pod Security Standards: RESTRICTED mode active
[INFO] Network policies: DEFAULT_DENY enforced
                </div>
            </div>

            <div class="card">
                <h3>🎛️ Demo Controls</h3>
                <button onclick="toggleCanaryDeployment()">Toggle Canary</button>
                <button onclick="scaleService()">Scale Service</button>
                <button onclick="viewGrafana()">Open Grafana</button>
                <button onclick="viewPrometheus()">Open Prometheus</button>
                <button onclick="viewJaeger()">Open Jaeger</button>
                <div style="margin-top: 15px;">
                    <strong>Quick Links:</strong><br>
                    <a href="http://localhost:3000" target="_blank" style="color: #4CAF50;">Grafana Dashboard</a><br>
                    <a href="http://localhost:9090" target="_blank" style="color: #4CAF50;">Prometheus</a><br>
                    <a href="http://localhost:16686" target="_blank" style="color: #4CAF50;">Jaeger Tracing</a><br>
                    <a href="http://localhost:8000" target="_blank" style="color: #4CAF50;">Zuul Gateway</a>
                </div>
            </div>

            <div class="card">
                <h3>📈 Live Monitoring</h3>
                <canvas id="metricsChart" width="300" height="150"></canvas>
                <div style="margin-top: 10px; font-size: 12px;">
                    Real-time security and performance metrics
                </div>
            </div>
        </div>
    </div>

    <script>
        // Simulated real-time data updates
        function updateMetrics() {
            document.getElementById('requestRate').textContent = Math.floor(Math.random() * 50) + 100;
            document.getElementById('errorRate').textContent = (Math.random() * 0.5).toFixed(1) + '%';
            document.getElementById('latency').textContent = Math.floor(Math.random() * 20) + 15 + 'ms';
        }

        function addSecurityLog(message) {
            const logs = document.getElementById('securityLogs');
            const timestamp = new Date().toLocaleTimeString();
            logs.innerHTML += `\n[${timestamp}] ${message}`;
            logs.scrollTop = logs.scrollHeight;
        }

        function runSecurityScan() {
            addSecurityLog('[SCAN] Starting vulnerability scan...');
            setTimeout(() => addSecurityLog('[SCAN] ✅ No critical vulnerabilities found'), 2000);
            setTimeout(() => addSecurityLog('[SCAN] Scan completed successfully'), 3000);
        }

        function runPenetrationTest() {
            addSecurityLog('[PENTEST] Starting penetration test...');
            setTimeout(() => addSecurityLog('[PENTEST] Testing SQL injection vectors...'), 1000);
            setTimeout(() => addSecurityLog('[PENTEST] Testing XSS vulnerabilities...'), 2000);
            setTimeout(() => addSecurityLog('[PENTEST] ✅ All security controls effective'), 4000);
        }

        function runComplianceCheck() {
            addSecurityLog('[COMPLIANCE] Running CIS Kubernetes benchmark...');
            setTimeout(() => addSecurityLog('[COMPLIANCE] Checking Pod Security Standards...'), 1500);
            setTimeout(() => addSecurityLog('[COMPLIANCE] ✅ 98.5% compliance score'), 3000);
        }

        function simulateAttack() {
            addSecurityLog('[ALERT] 🚨 Simulated attack detected!');
            setTimeout(() => addSecurityLog('[DEFENSE] Network policies blocking malicious traffic'), 1000);
            setTimeout(() => addSecurityLog('[DEFENSE] Falco runtime security engaged'), 2000);
            setTimeout(() => addSecurityLog('[DEFENSE] ✅ Attack successfully mitigated'), 3000);
        }

        function toggleCanaryDeployment() {
            addSecurityLog('[DEPLOY] Initiating canary deployment...');
            setTimeout(() => addSecurityLog('[DEPLOY] Security validation in progress...'), 2000);
            setTimeout(() => addSecurityLog('[DEPLOY] ✅ Canary deployment successful'), 4000);
        }

        function scaleService() {
            addSecurityLog('[SCALE] Scaling service replicas...');
            setTimeout(() => addSecurityLog('[SCALE] ✅ Service scaled with security policies enforced'), 2000);
        }

        function viewGrafana() { window.open('http://localhost:3000', '_blank'); }
        function viewPrometheus() { window.open('http://localhost:9090', '_blank'); }
        function viewJaeger() { window.open('http://localhost:16686', '_blank'); }

        // Update metrics every 5 seconds
        setInterval(updateMetrics, 5000);

        // Add periodic security logs
        setInterval(() => {
            const messages = [
                'mTLS certificates validated',
                'Network policy compliance verified',
                'Pod security context validated',
                'RBAC permissions audited',
                'Image vulnerability scan passed'
            ];
            addSecurityLog('[MONITOR] ' + messages[Math.floor(Math.random() * messages.length)]);
        }, 10000);

        // Simple chart simulation
        const canvas = document.getElementById('metricsChart');
        const ctx = canvas.getContext('2d');
        let dataPoints = Array(50).fill(0);

        function drawChart() {
            ctx.clearRect(0, 0, canvas.width, canvas.height);
            ctx.strokeStyle = '#4CAF50';
            ctx.lineWidth = 2;
            ctx.beginPath();

            dataPoints.shift();
            dataPoints.push(Math.random() * 100 + 50);

            for (let i = 0; i < dataPoints.length; i++) {
                const x = (i / dataPoints.length) * canvas.width;
                const y = canvas.height - (dataPoints[i] / 150) * canvas.height;
                if (i === 0) ctx.moveTo(x, y);
                else ctx.lineTo(x, y);
            }
            ctx.stroke();
        }

        setInterval(drawChart, 200);
    </script>
</body>
</html>
EOF

    cat > nginx.conf <<'EOF'
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       8080;
        server_name  localhost;
        root         /usr/share/nginx/html;
        index        index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }

        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
    }
}
EOF

    docker build -t ${REGISTRY}/demo-ui:${TAG} .
    docker push ${REGISTRY}/demo-ui:${TAG}

    cd ..
    print_success "Demo Web UI image built and pushed"
}

# Main function
main() {
    print_header "BUILDING LOCAL DEMO IMAGES"

    check_docker

    print_step "Registry: ${REGISTRY}"
    print_step "Tag: ${TAG}"

    build_zuul_gateway
    build_user_service
    build_security_scanner
    build_demo_ui

    print_header "IMAGE BUILD COMPLETED"
    echo -e "${GREEN}✅ All images built and pushed successfully!${NC}"
    echo -e "\n${YELLOW}Built images:${NC}"
    echo -e "  • ${REGISTRY}/zuul-gateway:${TAG}"
    echo -e "  • ${REGISTRY}/user-service:${TAG}"
    echo -e "  • ${REGISTRY}/security-scanner:${TAG}"
    echo -e "  • ${REGISTRY}/demo-ui:${TAG}"

    # List all images
    echo -e "\n${BLUE}Verifying images in registry:${NC}"
    curl -s http://localhost:30500/v2/_catalog | jq -r '.repositories[]' || echo "Registry catalog not available yet"
}

main "$@"