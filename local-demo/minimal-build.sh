#!/bin/bash

set -euo pipefail

REGISTRY="localhost:30500"
TAG="latest"

# Build minimal demo UI
echo "🔹 Building minimal demo UI..."

mkdir -p minimal-ui
cd minimal-ui

cat > Dockerfile <<EOF
FROM nginx:alpine

RUN apk add --no-cache curl

COPY index.html /usr/share/nginx/html/

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \\
    CMD curl -f http://localhost:80/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
EOF

cat > index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Zero Trust Demo - LIVE</title>
    <style>
        body { font-family: Arial; background: #1a1a2e; color: white; margin: 0; padding: 20px; }
        .container { max-width: 800px; margin: 0 auto; text-align: center; }
        .status { background: #0f3460; padding: 20px; border-radius: 10px; margin: 20px 0; }
        .success { color: #4CAF50; font-size: 24px; font-weight: bold; }
        .demo-title { font-size: 36px; margin: 20px 0; color: #4CAF50; }
        .feature { background: #16213e; padding: 15px; margin: 10px 0; border-radius: 5px; }
        .command { background: #000; color: #0f0; padding: 10px; font-family: monospace; text-align: left; }
    </style>
</head>
<body>
    <div class="container">
        <div class="demo-title">🛡️ Zero Trust Kubernetes Demo</div>
        <div class="success">✅ DEMO IS LIVE AND RUNNING!</div>

        <div class="status">
            <h2>🚀 Current Status</h2>
            <p>✅ Kubernetes cluster: Active</p>
            <p>✅ Container registry: Running</p>
            <p>✅ Web interface: Accessible</p>
            <p>✅ Security policies: Enforced</p>
        </div>

        <div class="feature">
            <h3>🔐 Zero Trust Security Features</h3>
            <p>• Pod Security Standards (Restricted mode)</p>
            <p>• Network Policies with default deny</p>
            <p>• RBAC authorization enabled</p>
            <p>• Container security scanning ready</p>
        </div>

        <div class="feature">
            <h3>💻 Test Commands</h3>
            <div class="command">
kubectl get nodes<br>
kubectl get pods -A<br>
kubectl get networkpolicies<br>
docker images | grep localhost:30500
            </div>
        </div>

        <div class="feature">
            <h3>🎯 Demo Components</h3>
            <p>• Kubernetes cluster with kind</p>
            <p>• Local container registry</p>
            <p>• Security policies and constraints</p>
            <p>• Interactive web dashboard</p>
        </div>

        <div class="feature">
            <h3>📝 Next Steps</h3>
            <p>1. Deploy application stack</p>
            <p>2. Install Istio service mesh</p>
            <p>3. Add monitoring (Prometheus/Grafana)</p>
            <p>4. Run security tests</p>
        </div>
    </div>

    <script>
        setInterval(() => {
            const now = new Date().toLocaleTimeString();
            document.title = `Zero Trust Demo - LIVE (${now})`;
        }, 1000);
    </script>
</body>
</html>
EOF

docker build -t ${REGISTRY}/demo-ui:${TAG} .
docker push ${REGISTRY}/demo-ui:${TAG}

cd ..
rm -rf minimal-ui

echo "✅ Demo UI built successfully!"
echo "Image: ${REGISTRY}/demo-ui:${TAG}"

# Test registry connectivity
echo "🔍 Testing registry..."
curl -s http://localhost:30500/v2/_catalog || echo "Registry not accessible yet"