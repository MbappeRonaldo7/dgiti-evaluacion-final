// ---------------------------------------------------------------------------
// Prueba de carga con k6 contra el Application Load Balancer.
//
// Uso:
//   k6 run -e BASE_URL=http://<alb-dns> load-test/k6-load.js            (completa, ~4 min)
//   k6 run -e BASE_URL=http://<alb-dns> -e PROFILE=short load-test/k6-load.js  (corta, ~70 s)
//
// Mide: tiempo de respuesta (http_req_duration), usuarios virtuales (vus),
// porcentaje de errores (http_req_failed) y comportamiento bajo carga.
// ---------------------------------------------------------------------------
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
if (!BASE_URL) {
  throw new Error('Defina BASE_URL, por ejemplo: -e BASE_URL=http://mi-alb.us-east-1.elb.amazonaws.com');
}

const profiles = {
  // Rampa hasta 150 usuarios virtuales para buscar el punto de saturación
  full: [
    { duration: '30s', target: 20 },
    { duration: '1m', target: 50 },
    { duration: '1m', target: 100 },
    { duration: '1m', target: 150 },
    { duration: '30s', target: 0 },
  ],
  // Versión corta para ejecutar en vivo durante el video
  short: [
    { duration: '15s', target: 30 },
    { duration: '40s', target: 80 },
    { duration: '15s', target: 0 },
  ],
};

export const options = {
  stages: profiles[__ENV.PROFILE || 'full'],
  thresholds: {
    http_req_failed: ['rate<0.05'],                 // menos del 5 % de errores
    http_req_duration: ['p(95)<1500'],              // p95 por debajo de 1.5 s
    'http_req_duration{endpoint:health}': ['p(95)<500'],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'max'],
};

const workDuration = new Trend('work_endpoint_ms', true);

export default function () {
  const r = Math.random();
  let res;

  if (r < 0.3) {
    res = http.get(`${BASE_URL}/health`, { tags: { endpoint: 'health' } });
  } else if (r < 0.8) {
    res = http.get(`${BASE_URL}/api/work?n=20000`, { tags: { endpoint: 'work' } });
    workDuration.add(res.timings.duration);
  } else if (r < 0.9) {
    res = http.get(`${BASE_URL}/api/visits`, { tags: { endpoint: 'visits_read' } });
  } else {
    res = http.post(`${BASE_URL}/api/visits`, null, { tags: { endpoint: 'visits_write' } });
  }

  check(res, {
    'status 2xx': (x) => x.status >= 200 && x.status < 300,
  });

  sleep(0.5);
}
