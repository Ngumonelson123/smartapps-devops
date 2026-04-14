# Dockerfile  — SmartApps Microservice
# Strategy  : Multi-stage build
#   Stage 1 (builder) — install ALL dependencies, run tests
#   Stage 2 (runtime) — copy only production artefacts; no dev tools
# Security  : Non-root user, read-only filesystem recommendation

# Stage 1: Builder
FROM node:20-alpine AS builder

# Build-time arguments injected by deploy.sh
ARG APP_VERSION=0.0.0
ARG BUILD_ENV=development

WORKDIR /build

COPY app/package*.json ./

# Install ALL dependencies
RUN npm ci

COPY app/src ./src
COPY app/server.test.js ./

# Run unit tests inside builder — if tests fail, the image is NOT built
RUN npm test

# Prune dev dependencies — only production deps go into final image
RUN npm prune --production

# Stage 2: Runtime
FROM node:20-alpine AS runtime

# Metadata labels
ARG APP_VERSION=0.0.0
ARG BUILD_ENV=development

LABEL org.opencontainers.image.title="smartapps-service"
LABEL org.opencontainers.image.version="${APP_VERSION}"
LABEL org.opencontainers.image.description="SmartApps microservice"
LABEL org.opencontainers.image.vendor="Smart Applications International"
LABEL build.environment="${BUILD_ENV}"

# Security hardening
RUN apk update && apk upgrade && \
    apk add --no-cache curl && \
    rm -rf /var/cache/apk/*

WORKDIR /app

# Create non-root user and group — never run as root in production
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy only what is needed from builder stage
COPY --from=builder --chown=appuser:appgroup /build/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /build/src ./src

# Switch to non-root user for security and runtime permissions
USER appuser

# Runtime environment variables
ENV NODE_ENV=${BUILD_ENV}
ENV APP_ENV=${BUILD_ENV}
ENV APP_VERSION=${APP_VERSION}
ENV PORT=8080

EXPOSE 8080

# Built-in health check used by:docker ps (shows healthy/unhealthy)
HEALTHCHECK \
  --interval=15s \
  --timeout=5s \
  --start-period=10s \
  --retries=3 \
  CMD curl -sf http://localhost:8080/health || exit 1

# Use exec form (not shell form) — ensures PID 1 gets SIGTERM for graceful shutdown
CMD ["node", "src/server.js"]
