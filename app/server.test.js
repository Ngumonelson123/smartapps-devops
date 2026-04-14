/**
 * SmartApps Service — Unit & Integration Tests
 * Tests the /health and /ready endpoints required by the pipeline validation step.
 * Run with: npm test
 */

'use strict';

const request = require('supertest');
const app     = require('./src/server');

describe('Health & Readiness Endpoints', () => {

  test('GET /health returns 200 with healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body.service).toBe('smartapps-service');
    expect(res.body).toHaveProperty('version');
    expect(res.body).toHaveProperty('timestamp');
  });

  test('GET /ready returns 200 with ready status', async () => {
    const res = await request(app).get('/ready');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ready');
  });

  test('GET / returns 200 with service info', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.body.message).toContain('SmartApps');
  });

});
