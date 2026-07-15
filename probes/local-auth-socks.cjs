'use strict';

const net = require('net');
const listenHost = '127.0.0.1';
const listenPort = 39082;
const routeHost = '127.0.0.1';
const routePort = 39081;
const expectedUser = 'pr2260';
const expectedPass = 'local-only';

function parseAddress(buffer, offset, atyp) {
  if (atyp === 1) {
    if (buffer.length < offset + 4) return null;
    return { host: [...buffer.subarray(offset, offset + 4)].join('.'), next: offset + 4 };
  }
  if (atyp === 3) {
    if (buffer.length < offset + 1) return null;
    const len = buffer[offset];
    if (buffer.length < offset + 1 + len) return null;
    return { host: buffer.subarray(offset + 1, offset + 1 + len).toString('utf8'), next: offset + 1 + len };
  }
  if (atyp === 4) {
    if (buffer.length < offset + 16) return null;
    const groups = [];
    for (let i = 0; i < 16; i += 2) groups.push(buffer.readUInt16BE(offset + i).toString(16));
    return { host: groups.join(':'), next: offset + 16 };
  }
  return { error: true };
}

const server = net.createServer((client) => {
  let state = 'greeting';
  let pending = Buffer.alloc(0);
  let upstream = null;

  const fail = (message) => {
    process.stdout.write(`FAIL ${message}\n`);
    client.destroy();
    if (upstream) upstream.destroy();
  };

  const consume = () => {
    while (true) {
      if (state === 'greeting') {
        if (pending.length < 2) return;
        const version = pending[0];
        const methodsLength = pending[1];
        if (pending.length < 2 + methodsLength) return;
        const methods = pending.subarray(2, 2 + methodsLength);
        pending = pending.subarray(2 + methodsLength);
        if (pending.length > 1024 * 1024) return fail('oversized greeting');
        if (version !== 5 || !methods.includes(2)) {
          client.write(Buffer.from([5, 0xff]));
          return fail('username/password auth not offered');
        }
        client.write(Buffer.from([5, 2]));
        state = 'auth';
        continue;
      }

      if (state === 'auth') {
        if (pending.length < 2) return;
        const userLength = pending[1];
        if (pending.length < 2 + userLength + 1) return;
        const passwordLength = pending[2 + userLength];
        const total = 3 + userLength + passwordLength;
        if (pending.length < total) return;
        const user = pending.subarray(2, 2 + userLength).toString('utf8');
        const password = pending.subarray(3 + userLength, total).toString('utf8');
        pending = pending.subarray(total);
        const ok = user === expectedUser && password === expectedPass;
        process.stdout.write(`AUTH user=${user} result=${ok ? 'ok' : 'denied'}\n`);
        client.write(Buffer.from([1, ok ? 0 : 1]));
        if (!ok) return fail('bad credentials');
        state = 'request';
        continue;
      }

      if (state === 'request') {
        if (pending.length < 4) return;
        if (pending[0] !== 5 || pending[1] !== 1) return fail('unsupported request');
        const parsed = parseAddress(pending, 4, pending[3]);
        if (!parsed || parsed.error) return parsed?.error ? fail('bad address type') : undefined;
        if (pending.length < parsed.next + 2) return;
        const requestedPort = pending.readUInt16BE(parsed.next);
        pending = pending.subarray(parsed.next + 2);
        process.stdout.write(`CONNECT host=${parsed.host} port=${requestedPort} route=${routeHost}:${routePort}\n`);
        state = 'connecting';
        upstream = net.connect(routePort, routeHost, () => {
          client.write(Buffer.from([5, 0, 0, 1, 127, 0, 0, 1, (routePort >> 8) & 255, routePort & 255]));
          if (pending.length) upstream.write(pending);
          pending = Buffer.alloc(0);
          state = 'stream';
          client.pipe(upstream);
          upstream.pipe(client);
        });
        upstream.on('error', (error) => fail(`route error ${error.message}`));
        return;
      }
      return;
    }
  };

  client.on('data', (chunk) => {
    if (state === 'stream') return;
    pending = Buffer.concat([pending, chunk]);
    consume();
  });
  client.on('error', () => { if (upstream) upstream.destroy(); });
  client.on('close', () => { if (upstream) upstream.destroy(); });
});

server.listen(listenPort, listenHost, () => process.stdout.write(`READY socks5-auth ${listenHost}:${listenPort}\n`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));

