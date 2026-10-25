'use strict';
// cajeta-http bench: Node.js competitor client (undici fetch + Agent).
const { fetch, Agent } = require('undici');

const [cmd, url, totalStr, connsStr, kaStr] = process.argv.slice(2);
const total = Number(totalStr);
const conns = Number(connsStr);
if (cmd !== 'get' || !url || !Number.isInteger(total) || total < 0 ||
    !Number.isInteger(conns) || conns < 1 || (kaStr !== '0' && kaStr !== '1')) {
  console.error('usage: client.js get <url> <total> <conns> <keepalive 0|1>');
  process.exit(2);
}
const keepalive = kaStr === '1';
const EXPECTED = 'Hello, World!';

// keepalive=1: one pooled Agent sized to <conns> connections (default pipelining 1 = keep-alive).
// keepalive=0: pipelining 0 disables keep-alive in undici, so every request gets a fresh connection.
const dispatcher = keepalive
  ? new Agent({ connections: conns })
  : new Agent({ connections: conns, pipelining: 0 });

let next = 0;
let completed = 0;
let errors = 0;

async function worker() {
  while (next < total) {
    next++;
    try {
      const res = await fetch(url, { dispatcher });
      const body = await res.text();
      if (res.status === 200 && body === EXPECTED) completed++;
      else errors++;
    } catch {
      errors++;
    }
  }
}

(async () => {
  const workers = Math.min(conns, Math.max(total, 1));
  const start = process.hrtime.bigint();
  await Promise.all(Array.from({ length: workers }, worker));
  const elapsed = process.hrtime.bigint() - start;
  process.stdout.write(JSON.stringify({ requests: completed, errors, elapsed_ns: Number(elapsed) }) + '\n');
  await dispatcher.close().catch(() => {});
  process.exit(0);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
