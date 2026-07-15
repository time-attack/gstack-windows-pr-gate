'use strict';

const http = require('http');
const host = '127.0.0.1';
const port = 39081;

const page = `<!doctype html>
<html><head><meta charset="utf-8"><title>PR2260 local fixture</title>
<style>html,body{margin:0}main{min-height:3600px;background:linear-gradient(#f8fafc,#cbd5e1);padding:40px;font-family:system-ui}h1{font-size:48px}</style>
</head><body><main><h1>PR2260 SOCKS SHARP FIXTURE</h1><p>Local-only deterministic page.</p></main></body></html>`;

const server = http.createServer((req, res) => {
  process.stdout.write(`REQUEST method=${req.method} url=${req.url} host=${req.headers.host || ''}\n`);
  res.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'content-length': Buffer.byteLength(page),
    'cache-control': 'no-store',
  });
  res.end(page);
});

server.listen(port, host, () => process.stdout.write(`READY http ${host}:${port}\n`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));

