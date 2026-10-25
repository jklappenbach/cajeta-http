'use strict';
// cajeta-http bench: Node.js competitor server. One process, no cluster.
const fs = require('node:fs');

const [mode, portStr, certPath, keyPath] = process.argv.slice(2);
const port = Number(portStr);
const HOST = '127.0.0.1';
if (!mode || !Number.isInteger(port) || port <= 0) {
  console.error('usage: server.js <h1|h2c|tls> <port> [<cert.pem> <key.pem>]');
  process.exit(2);
}

const PLAIN = Buffer.from('Hello, World!');
const PLAIN_LEN = String(PLAIN.length);

function plaintext(res) {
  res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': PLAIN_LEN });
  res.end(PLAIN);
}

function json(res) {
  const body = JSON.stringify({ message: 'Hello, World!' });
  res.writeHead(200, {
    'Content-Type': 'application/json',
    'Content-Length': String(Buffer.byteLength(body)),
  });
  res.end(body);
}

function notFound(res) {
  res.writeHead(404, { 'Content-Length': '0' });
  res.end();
}

function sse(req, res) {
  const q = req.url.indexOf('?');
  let n = 1000;
  if (q >= 0) {
    const v = new URLSearchParams(req.url.slice(q + 1)).get('n');
    if (v !== null) {
      const parsed = Number.parseInt(v, 10);
      if (Number.isFinite(parsed) && parsed >= 0) n = parsed;
    }
  }
  res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
  // res.write per event; Node flushes each write to the socket (chunked).
  for (let i = 0; i < n; i++) res.write('data: ' + i + '\n\n');
  res.end();
}

function pathOf(url) {
  const q = url.indexOf('?');
  return q < 0 ? url : url.slice(0, q);
}

function h1Handler(req, res) {
  res.sendDate = false;
  const p = pathOf(req.url);
  if (req.method === 'GET' || req.method === 'HEAD') {
    if (p === '/plaintext') return plaintext(res);
    if (p === '/json') return json(res);
    if (p === '/sse') return sse(req, res);
  }
  notFound(res);
}

function countConnections(server) {
  // Diagnostic only (BENCH_COUNT_CONNS=1): report accepted TCP connections on SIGUSR2 to stderr.
  if (process.env.BENCH_COUNT_CONNS !== '1') return;
  let conns = 0;
  server.on('connection', () => { conns++; });
  process.on('SIGUSR2', () => { process.stderr.write(`connections=${conns}\n`); });
}

if (mode === 'h1') {
  const http = require('node:http');
  const { WebSocketServer } = require('ws');
  const server = http.createServer(h1Handler);
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: 64 * 1024 * 1024,
    perMessageDeflate: { threshold: 0 },
  });
  wss.on('connection', (ws) => {
    ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
    ws.on('error', () => {});
  });
  server.on('upgrade', (req, socket, head) => {
    if (pathOf(req.url) !== '/ws') {
      socket.end('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  });
  countConnections(server);
  server.listen(port, HOST);
} else if (mode === 'h2c') {
  const http2 = require('node:http2');
  const server = http2.createServer(
    { settings: { maxConcurrentStreams: 256 } },
    (req, res) => {
      const p = pathOf(req.url);
      if (req.method === 'GET' || req.method === 'HEAD') {
        if (p === '/plaintext') return plaintext(res);
        if (p === '/json') return json(res);
      }
      notFound(res);
    },
  );
  server.on('sessionError', () => {});
  server.listen(port, HOST);
} else if (mode === 'tls') {
  if (!certPath || !keyPath) {
    console.error('tls mode needs <cert.pem> <key.pem>');
    process.exit(2);
  }
  const https = require('node:https');
  const server = https.createServer(
    {
      cert: fs.readFileSync(certPath),
      key: fs.readFileSync(keyPath),
      minVersion: 'TLSv1.2',
      ALPNProtocols: ['http/1.1'],
    },
    (req, res) => {
      res.sendDate = false;
      const p = pathOf(req.url);
      if ((req.method === 'GET' || req.method === 'HEAD') && p === '/plaintext') return plaintext(res);
      notFound(res);
    },
  );
  server.on('tlsClientError', () => {});
  countConnections(server);
  server.listen(port, HOST);
} else {
  console.error(`unknown mode: ${mode}`);
  process.exit(2);
}
