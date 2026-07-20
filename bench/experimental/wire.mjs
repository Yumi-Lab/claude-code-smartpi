// EXPERIMENTAL — binary wire framing for the Claude Code job daemon socket.
//
// Today the daemon ships agent stdout/stderr as base64 inside newline-JSON
// ({type:'out', data:'<base64>', enc:'b64'}) — a flat +33% on the wire plus a
// base64 encode on the daemon and a decode on the client for every chunk.
//
// This module carries the SAME messages as length-prefixed binary frames:
//     [1 byte type][4 bytes big-endian length][payload]
//     type 1 = JSON control (run/started/queued/exit), 2 = stdout, 3 = stderr
// Control messages stay JSON (small, structured); output DATA travels raw — no
// base64 bytes, no per-chunk transcode. Not wired into the production daemon yet;
// promote by swapping the daemon/client send+decode once the bench validates it.

export const T_JSON = 1, T_OUT = 2, T_ERR = 3;

// ---- binary framing (the experimental protocol) ----
export function frame(type, payload) {
  const buf = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
  const head = Buffer.allocUnsafe(5);
  head[0] = type;
  head.writeUInt32BE(buf.length, 1);
  return Buffer.concat([head, buf], 5 + buf.length);
}
export const frameJSON = (obj) => frame(T_JSON, JSON.stringify(obj));

// Streaming decoder: feed raw socket chunks, get whole frames back (handles a
// frame split across reads and several frames in one read).
export function createDecoder(onFrame) {
  let buf = Buffer.alloc(0);
  return (chunk) => {
    buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
    while (buf.length >= 5) {
      const len = buf.readUInt32BE(1);
      if (buf.length < 5 + len) break;
      onFrame(buf[0], buf.subarray(5, 5 + len));
      buf = buf.subarray(5 + len);
    }
  };
}

// ---- base64-in-JSON (the CURRENT production protocol), for comparison ----
export function b64Encode(type, payload) {
  const t = type === T_OUT ? 'out' : type === T_ERR ? 'err' : 'ctl';
  return Buffer.from(JSON.stringify({ type: t, data: payload.toString('base64'), enc: 'b64' }) + '\n');
}
export function createB64Decoder(onMsg) {
  let s = '';
  return (chunk) => {
    s += chunk.toString('binary');
    let nl;
    while ((nl = s.indexOf('\n')) >= 0) {
      const line = s.slice(0, nl); s = s.slice(nl + 1);
      if (!line.trim()) continue;
      const m = JSON.parse(line);
      onMsg(m.type, Buffer.from(m.data, 'base64'));
    }
  };
}
