/**
 * SmartApps Microservice
 * A minimal Express.js service used to demonstrate the full DevOps pipeline.
 * Exposes /health and /ready endpoints required by Docker HEALTHCHECK,
 * Kubernetes probes, and the deployment validation script.
 */

'use strict';

const express = require('express');
const app     = express();
const PORT    = process.env.PORT || 8080;
const ENV     = process.env.APP_ENV  || 'development';
const VERSION = process.env.APP_VERSION || '0.0.0';

app.use(express.json());

// Health check- used by Docker HEALTHCHECK + K8s liveness probe
app.get('/health', (req, res) => {
  res.status(200).json({
    status:    'healthy',
    service:   'smartapps-service',
    version:   VERSION,
    env:       ENV,
    timestamp: new Date().toISOString(),
  });
});

// Readiness check-used by K8s readiness probe
app.get('/ready', (req, res) => {
  res.status(200).json({
    status:  'ready',
    version: VERSION,
    env:     ENV,
  });
});

// Root endpoint
app.get('/', (req, res) => {
  res.status(200).json({
    message: 'SmartApps Microservice is running',
    version: VERSION,
    env:     ENV,
  });
});

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`[SmartApps] Service started on port ${PORT} | env=${ENV} | version=${VERSION}`);
  });
}

module.exports = app;
