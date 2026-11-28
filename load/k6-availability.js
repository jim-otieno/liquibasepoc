// Availability probe + steady mixed load during a migration phase.
// Every failed or slow (> 2 s) request counts against availability.
//
//   k6 run -e BASE_URL=http://localhost:8080 -e RATE=10 -e DURATION=5m \
//          --out json=results/probe.json load/k6-availability.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const RATE = Number(__ENV.RATE || 10);            // requests per second
const DURATION = __ENV.DURATION || '5m';
const MAX_ID = Number(__ENV.MAX_ID || 1000);      // ids known to exist after seeding

export const unavailable = new Counter('zdm_unavailable_requests');
export const availability = new Rate('zdm_available');

export const options = {
  scenarios: {
    probe: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: {
    zdm_available: ['rate>0.999'],
    http_req_duration: ['p(99)<500'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(95)', 'p(99)'],
};

const params = { headers: { 'Content-Type': 'application/json' }, timeout: '2s' };

export default function () {
  const r = Math.random();
  let res;
  if (r < 0.6) {
    const id = 1 + Math.floor(Math.random() * MAX_ID);
    res = http.get(`${BASE}/customers/${id}`, Object.assign({ tags: { op: 'read' } }, params));
  } else if (r < 0.9) {
    const n = Math.floor(Math.random() * 1e9);
    res = http.post(`${BASE}/customers`,
      JSON.stringify({ name: `Probe ${n}`, email: `probe${n}@example.org` }),
      Object.assign({ tags: { op: 'create' } }, params));
  } else {
    const id = 1 + Math.floor(Math.random() * MAX_ID);
    res = http.put(`${BASE}/customers/${id}`, JSON.stringify({ name: `Renamed ${id}` }),
      Object.assign({ tags: { op: 'update' } }, params));
  }
  // 404 on a random id is a valid answer, not an outage.
  const ok = check(res, { 'served': (x) => x.status > 0 && x.status < 500 });
  availability.add(ok);
  if (!ok) unavailable.add(1);
}
