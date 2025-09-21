# Multi-stage build for security
FROM openjdk:21-jdk-slim as builder

# Install security scanning tools
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install Syft for SBOM generation
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

WORKDIR /app
COPY . .

# Build the application
RUN ./gradlew build -x test

# Generate SBOM
RUN syft /app -o spdx-json=zuul-sbom.spdx.json

# Runtime stage
FROM openjdk:21-jre-slim

# Create non-root user for security
RUN groupadd -r zuul && useradd -r -g zuul zuul

# Install security tools in runtime
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application and SBOM
COPY --from=builder /app/zuul-sample/build/libs/*.jar zuul-gateway.jar
COPY --from=builder /app/zuul-sbom.spdx.json /app/sbom/

# Set security-focused ownership and permissions
RUN chown -R zuul:zuul /app && \
    chmod -R 755 /app && \
    chmod 644 /app/zuul-gateway.jar

# Switch to non-root user
USER zuul

# Security labels
LABEL \
    io.opencontainers.image.title="Zuul Security Gateway" \
    io.opencontainers.image.description="Netflix Zuul API Gateway with security enhancements" \
    io.opencontainers.image.vendor="Netflix/Security" \
    io.opencontainers.image.licenses="Apache-2.0" \
    security.scan.sbom="/app/sbom/zuul-sbom.spdx.json"

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Run application
ENTRYPOINT ["java", "-jar", "-Djava.security.egd=file:/dev/./urandom", "zuul-gateway.jar"]