// EXPERIMENTAL bench — base64-in-JSON (current daemon protocol) vs binary framing.
// Measures, per output volume: bytes on the wire, encode CPU (daemon side),
// decode CPU (client side), and a real end-to-end pass over a Unix socket with an
// integrity check. Run:  node bench/experimental/wire-bench.mjs
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import {
  frame, createDecoder, b64Encode, createB64Decoder, T_OUT,
} from './wire.mjs';

const CHUNK = 8192;                                   // a typical stdout 'data' chunk
const SIZES = [64 * 1024, 512 * 1024, 4 * 1024 * 1024];
const REPS = 20;                                      // encode/decode CPU repetitions
const SAMPLE = Buffer.from('The quick brown fox jumps over the lazy dog 0123456789. '.repeat(2000));

function chunksFor(total) {
  const out = [];
  for (let off = 0; off < total; off += CHUNK) {
    const n = Math.min(CHUNK, total - off);
    out.push(SAMPLE.subarray(off % (SAMPLE.length - CHUNK), (off % (SAMPLE.length - CHUNK)) + n));
  }
  return out;
}

function ms(fn) { const t = performance.now(); fn(); return performance.now() - t; }
function fmt(n) { return n >= 1048576 ? (n / 1048576).toFixed(1) + 'MB' : (n / 1024).toFixed(0) + 'KB'; }

async function e2e(encode, makeDecoder, chunks) {
  // server sends all encoded frames; client decodes and counts bytes; measure wall
  return new Promise((resolve) => {
    const sock = path.join(os.tmpdir(), `wire-bench-${process.pid}-${Math.floor(performance.now())}.sock`);
    let got = 0;
    const server = net.createServer((c) => {
      for (const ch of chunks) c.write(encode(T_OUT, ch));
      c.end();
    });
    server.listen(sock, () => {
      const t = performance.now();
      const client = net.connect(sock);
      const decode = makeDecoder((_type, payload) => { got += payload.length; });
      client.on('data', decode);
      client.on('close', () => { server.close(() => resolve({ wall: performance.now() - t, got })); });
    });
  });
}

console.log(`chunk=${CHUNK}B  reps=${REPS}  node=${process.version}  arch=${process.arch}\n`);
console.log('size   proto   wire_bytes   overhead   encode_ms   decode_ms   e2e_ms   ok');
console.log('-----  ------  -----------  ---------  ----------  ----------  -------  ---');

for (const size of SIZES) {
  const chunks = chunksFor(size);
  const raw = chunks.reduce((a, c) => a + c.length, 0);

  for (const proto of ['base64', 'binary']) {
    const encode = proto === 'base64' ? b64Encode : frame;
    const makeDec = proto === 'base64' ? createB64Decoder : createDecoder;

    // wire bytes
    const wire = chunks.reduce((a, c) => a + encode(T_OUT, c).length, 0);

    // encode CPU (daemon side)
    const encMs = ms(() => { for (let r = 0; r < REPS; r++) for (const c of chunks) encode(T_OUT, c); }) / REPS;

    // decode CPU (client side)
    const encoded = Buffer.concat(chunks.map((c) => encode(T_OUT, c)));
    let decMs = 0;
    decMs = ms(() => {
      for (let r = 0; r < REPS; r++) {
        let n = 0; const dec = makeDec((_t, p) => { n += p.length; });
        dec(encoded);
      }
    }) / REPS;

    const { wall, got } = await e2e(encode, makeDec, chunks);
    const ok = got === raw ? 'yes' : `NO(${got}/${raw})`;
    const overhead = ((wire - raw) / raw * 100).toFixed(1) + '%';
    console.log(
      `${fmt(size).padEnd(5)}  ${proto.padEnd(6)}  ${String(wire).padStart(11)}  ${overhead.padStart(9)}  ` +
      `${encMs.toFixed(2).padStart(10)}  ${decMs.toFixed(2).padStart(10)}  ${wall.toFixed(1).padStart(7)}  ${ok}`);
  }
  console.log('');
}
