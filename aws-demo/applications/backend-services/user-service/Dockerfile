# Multi-stage build for User Service
FROM openjdk:21-jdk-slim as builder

# Install security scanning tools
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Syft for SBOM generation
RUN curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

WORKDIR /app

# Copy source code
COPY src/ ./src/
COPY pom.xml ./
COPY mvnw ./
COPY .mvn ./.mvn

# Build the application
RUN ./mvnw clean package -DskipTests

# Generate SBOM
RUN syft /app -o spdx-json=user-service-sbom.spdx.json

# Runtime stage
FROM openjdk:21-jre-slim

# Create non-root user for security
RUN groupadd -r userservice && useradd -r -g userservice userservice

# Install runtime security tools
RUN apt-get update && apt-get install -y \
    curl \
    dumb-init \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy application and SBOM
COPY --from=builder /app/target/*.jar user-service.jar
COPY --from=builder /app/user-service-sbom.spdx.json /app/sbom/

# Set security-focused ownership and permissions
RUN chown -R userservice:userservice /app && \
    chmod -R 755 /app && \
    chmod 644 /app/user-service.jar

# Switch to non-root user
USER userservice

# Security labels
LABEL \
    io.opencontainers.image.title="User Service" \
    io.opencontainers.image.description="User management microservice with zero trust security" \
    io.opencontainers.image.vendor="Demo/Security" \
    io.opencontainers.image.licenses="Apache-2.0" \
    security.scan.sbom="/app/sbom/user-service-sbom.spdx.json" \
    security.compliance.level="high"

# Expose port
EXPOSE 8081

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8081/actuator/health || exit 1

# Use dumb-init for proper signal handling
ENTRYPOINT ["dumb-init", "--"]
CMD ["java", "-jar", "-Djava.security.egd=file:/dev/./urandom", "-XX:+UseContainerSupport", "user-service.jar"]